#!/bin/bash

set -xe

echo "Deploy to Artifactory."
# more bash-friendly output for jq
JQ="jq --raw-output --exit-status"

configure_aws_cli(){
  if [ $# != 1 ] ; then
    echo "AWS Region required."
    exit 1;
  fi
  aws --version
  aws configure set default.region $1
  echo "aws_region $1"
  aws configure set default.output json

}

get_current_task_definition(){
  if [ $# != 1 ] ; then
    echo "Task definition family required."
    exit 1;
  fi
  echo "Getting current task definition for family $1."
  CURRENT_TASK_DEF=$(aws ecs describe-task-definition --task-definition $1)

  #Remove the quotes and the last part after the : which is the image tag
  CURRENT_IMAGE_REPO_URL=$(echo $CURRENT_TASK_DEF \
                        | $JQ '.taskDefinition.containerDefinitions' \
                        | $JQ  '.[0].image' | sed 's/"//g' | cut -d: -f-1)
  if [[ -z "$CURRENT_IMAGE_REPO_URL" ]]; then 
    echo "Error: Could not extract the CURRENT_IMAGE_REPO_URL from the task definition"; exit 1;
  fi
}

get_version_tag(){
  #let tag=$(date +%g%q) does not work in circleci/python:2.7.13 image
  tag=$(date +"%g %m" | awk '{q=int($2/4)+1; printf("%s%s\n", $1, q);}')
  month=$(date +%m)
  #let prev_release=$1
  #release=$(($prev_release+1))
  version=$1
  mq=$((10#$month % 3 == 0 ? 3 : 10#$month % 3))
  tag+="$mq"."$version"
  VERSION_TAG=$tag
}

generate_tags(){
  get_version_tag $CODEBUILD_BUILD_NUMBER
  
  SHORT_COMMIT_HASH=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c1-7)
  RELEASE_TAG=$(echo $CODEBUILD_SOURCE_VERSION | cut -c1-7)
  #RELEASE_BRANCH=$(echo "$CIRCLE_BRANCH" | sed -r 's/[//\]+/-/g')

  RELEASE_BRANCH=main

  #PACKAGE_VERSION="" #$(sed -nE 's/^\s*"version": "(.*?)",$/\1/p' package.json)

  echo "tags generated: version=$VERSION_TAG, Short commit=$SHORT_COMMIT_HASH, \
        release tag=$RELEASE_TAG,branch=$RELEASE_BRANCH,package ver=$PACKAGE_VERSION"
}

docker_tag(){
  echo "docker tagging $1,$2"
  docker tag "$1" "$2"
  if [ $? -ne 0 ] ; then
    echo "docker tag failed. $1:$2"
    exit 1;
  fi
}
docker_push(){
  echo "docker pushing $1,$2"
  docker push "$1"
  if [ $? -ne 0 ] ; then
    echo "docker push failed. $1"
    exit 1;
  fi
}

push_docker_image(){
  if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ] || [ -z "$5" ] ; then
    echo "Docker image name,current repo url,commit hash,version tag,release branch,release tag required."
    echo "image=$1,repo=$2,commit=$3,version=$4,branch=$5,release tag=$6,package ver=$7"
    exit 1;
  fi
  echo "Docker build & push $1 with tags: latest,$3,$4,$5,$6,$7 to $2"
 
  docker build -t $1 .
  if [ $? -ne 0 ] ; then
    echo "docker build failed. $1"
    exit 1;
  fi

  docker_tag "$1:latest" "$2:latest"
  docker_tag "$1:latest" "$2:$3"
  docker_tag "$1:latest" "$2:$4"
  [ ! -z "$5" ] && docker_tag "$1:latest" "$2:$5"
  [ ! -z "$6" ] && docker_tag "$1:latest" "$2:$6"
  [ ! -z "$7" ] && docker_tag "$1:latest" "$2:$7"

  docker_push "$2:latest"
  docker_push "$2:$3"
  docker_push "$2:$4"
  [ ! -z "$5" ] && docker_push "$2:$5"
  [ ! -z "$6" ] && docker_push "$2:$6"
  [ ! -z "$7" ] && docker_push "$2:$7"
 
}
push_docker_image_to_ecr(){
  aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 095014417075.dkr.ecr.us-east-1.amazonaws.com
  push_docker_image "$@"
}


main(){
  if [ -z $1 ]; then
    echo "Deploy requires environment name (dev,qa,sit,demo,stage,prod,dr)"; exit 1;
  fi
  AWS_REGION="us-east-1"
  DOCKER_IMAGE_NAME="ecs-demo"
  if [ $1 == "dev" ]; then
    CLUSTER="dev-dc-ecs-cluster"
    
    TASK_FAMILY_API="API-Task"
    SERVICE_API="API-Service"

  elif [ $1 == "prod" ]; then
    AWS_ACCESS_KEY_ID=${AWS_PROD_ID}
    AWS_SECRET_ACCESS_KEY=${AWS_PROD_KEY}

    CLUSTER="prod-cda-cluster"
    TASK_FAMILY_API="prod-cda-API-Task"
    SERVICE_API="prod-cda-API-Service"
  else
    echo "Undefined environment:$1"; exit 1; 
  fi

  configure_aws_cli  $AWS_REGION
  echo " aws_region $AWS_REGION"
  get_current_task_definition $TASK_FAMILY_API
  echo  "Current Task ECS Repo:$CURRENT_IMAGE_REPO_URL"

  if [ $1 == "dev" ] || [ $1 == "dr" ]; then
    generate_tags
    
    artifactory_repo_url=095014417075.dkr.ecr.us-east-1.amazonaws.com

    echo "Docker artifactory URL:$artifactory_repo_url"

    push_docker_image_to_ecr $DOCKER_IMAGE_NAME $artifactory_repo_url $SHORT_COMMIT_HASH $VERSION_TAG $RELEASE_BRANCH $RELEASE_TAG $PACKAGE_VERSION
  else
    CURRENT_IMAGE_REPO_URL=$2
    SHORT_COMMIT_HASH=$3
  fi
   
  # --- API Task ---
  register_new_task_definition "$TASK_FAMILY_API" $CURRENT_IMAGE_REPO_URL $SHORT_COMMIT_HASH "$CURRENT_TASK_DEF"
  if [[ -z "$TASK_REVISON_ARN" ]]; then 
    echo "Error: Could not register task definition for $TASK_FAMILY_API"; exit 1; 
  fi

  update_service $CLUSTER $SERVICE_API $TASK_REVISON_ARN
  if [ $? -eq 1 ]; then
    echo "Error updating service in cluster $CLUSTER and service $SERVICE with $TASK_REVISON_ARN"; exit 1; 
  fi

  # if everything is ok, export the REPO to which it was published.
  if [[ ! -e $dir ]]; then
    mkdir -p workspace
    echo "export STUDIO_CI_CURRENT_IMAGE_TAG="$SHORT_COMMIT_HASH"" > workspace/env_exports
    echo "export STUDIO_CI_CURRENT_IMAGE_REPO_URL="$CURRENT_IMAGE_REPO_URL"" >> workspace/env_exports
    echo $(cat workspace/env_exports)
  fi 

}
main "$@"
