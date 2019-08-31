#! /bin/bash
set -e

if ! [ -x "$(command -v docker)" ]; then
  echo 'Docker client is required to continue'
  exit 1
fi

aws resource-groups create-group \
    --name DemoEnvironment \
    --resource-query '{"Type":"TAG_FILTERS_1_0", "Query":"{\"ResourceTypeFilters\":[\"AWS::AllSupported\"],\"TagFilters\":[{\"Key\":\"Environment\", \"Values\":[\"Demo\"]}]}"}' || echo "Group exists, continuing"

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
TASKREVISION=$(aws ecs register-task-definition --cli-input-json file://task-definition.json \
  --tags key=Environment,value=Demo --query "taskDefinition.revision" --output text)

#---- networking stuff

VPCID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query "Vpc.VpcId" --output text)
aws ec2 create-tags --resources $VPCID --tags Key=Environment,Value=Demo
SUBNETID=$(aws ec2 create-subnet --vpc-id $VPCID --cidr-block 10.0.1.0/24 \
  --availability-zone eu-central-1b \
  --query "Subnet.SubnetId" --output text)
SUBNET2ID=$(aws ec2 create-subnet --vpc-id $VPCID --cidr-block 10.0.2.0/24 \
  --availability-zone eu-central-1b \
  --query "Subnet.SubnetId" --output text)
aws ec2 create-tags --resources $SUBNETID --tags Key=Environment,Value=Demo
aws ec2 create-tags --resources $SUBNET2ID --tags Key=Environment,Value=Demo
GATEWAYID=$(aws ec2 create-internet-gateway --query "InternetGateway.InternetGatewayId" \
  --output text)
aws ec2 create-tags --resources $GATEWAYID --tags Key=Environment,Value=Demo
aws ec2 attach-internet-gateway --vpc-id $VPCID --internet-gateway-id $GATEWAYID

ROUTETABLEID=$(aws ec2 describe-route-tables --filter "Name=vpc-id,Values=$VPCID" \
  --query "RouteTables[0].RouteTableId" --output text)
aws ec2 create-route --route-table-id $ROUTETABLEID --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $GATEWAYID
aws ec2 associate-route-table  --subnet-id $SUBNETID --route-table-id $ROUTETABLEID
aws ec2 associate-route-table  --subnet-id $SUBNET2ID --route-table-id $ROUTETABLEID
SECURITYGROUPID=$(aws ec2 describe-security-groups \
  --filters Name=vpc-id,Values=$VPCID \
  --query "SecurityGroups[0].GroupId" --output text)
aws ec2 authorize-security-group-ingress --group-id $SECURITYGROUPID \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

#-----------

aws ecs create-service --cluster demo-cluster --service-name simple-app \
  --task-definition simple-app:$TASKREVISION --desired-count 1 --launch-type "FARGATE" \
  --scheduling-strategy REPLICA --deployment-controller '{"type": "ECS"}'\
  --deployment-configuration minimumHealthyPercent=100,maximumPercent=200 \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETID],securityGroups=[$SECURITYGROUPID],assignPublicIp=\"ENABLED\"}"
aws ecs wait services-stable --cluster demo-cluster --services simple-app
TASKARN=$(aws ecs list-tasks --cluster demo-cluster --query "taskArns[0]" --output text)
aws ecs wait tasks-running --tasks $TASKARN --cluster demo-cluster
PUBLICIP=$(aws ec2 describe-network-interfaces \
  --filters "Name=subnet-id,Values=$SUBNETID" \
  --query 'NetworkInterfaces[0].PrivateIpAddresses[0].Association.PublicIp' --output text)

echo "Task now reachable at $PUBLICIP"
echo "Checkpoint 1, press enter to continue"
read

#----------- Cleanup

aws ecs update-service --service simple-app --cluster demo-cluster --desired-count 0
aws ecs delete-service --service simple-app --cluster demo-cluster
aws ecs wait services-inactive --service simple-app --cluster demo-cluster

aws ecr delete-repository --repository-name simple-app --force
aws iam detach-role-policy --role-name ecsTaskExecutionRole --policy-arn $POLICYARN
aws iam delete-role --role-name ecsTaskExecutionRole
aws ecs deregister-task-definition --task-definition simple-app:$TASKREVISION
aws ecs delete-cluster --cluster demo-cluster

aws ec2 detach-internet-gateway --internet-gateway-id $GATEWAYID --vpc-id $VPCID
aws ec2 delete-internet-gateway --internet-gateway-id $GATEWAYID
aws ec2 delete-subnet --subnet-id $SUBNETID
aws ec2 delete-subnet --subnet-id $SUBNET2ID
aws ec2 delete-vpc --vpc-id $VPCID

aws resource-groups delete-group --group-name DemoEnvironment
