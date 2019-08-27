#! /bin/bash
set -e

if ! [ -x "$(command -v docker)" ]; then
  echo 'Docker client is required to continue'
  exit 1
fi

aws resource-groups create-group \
    --name DemoEnvironment \
    --resource-query '{"Type":"TAG_FILTERS_1_0", "Query":"{\"ResourceTypeFilters\":[\"AWS::AllSupported\"],\"TagFilters\":[{\"Key\":\"Environment\", \"Values\":[\"Demo\"]}]}"}'

REPOID=$(aws ecr create-repository --repository-name simple-app \
  --tags Key=Environment,Value=Demo \
  --query "repository.registryId" --output text)
REPOURL=$(aws ecr describe-repositories --repository-names simple-app \
  --query "repositories[0].repositoryUri" --output text)

$(aws ecr get-login --region eu-central-1 --no-include-email)

docker build -t $REPOURL:0.1 static-app/
docker push $REPOURL:0.1

aws ecs create-cluster --cluster-name demo-cluster --tags key=Environment,value=Demo

ROLEARN=$(aws iam create-role --role-name ecsTaskExecutionRole \
  --assume-role-policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":[\"ecs-tasks.amazonaws.com\"]},\"Action\":[\"sts:AssumeRole\"]}]}" \
  --query "Role.Arn" --output text)

POLICYARN=$(aws iam list-policies --query 'Policies[?PolicyName==`AmazonECSTaskExecutionRolePolicy`].{ARN:Arn}' \
  --output text)
aws iam attach-role-policy --role-name ecsTaskExecutionRole --policy-arn $POLICYARN

export ROLEARN REPOURL
envsubst < static-app/task-definition.json.tmpl > task-definition.json
aws ecs register-task-definition --cli-input-json file:///./static-app/task-definition.json \
  --tags key=Environment,value=Demo
