#! /bin/bash
set -e

if ! [ -x "$(command -v docker)" ]; then
  echo 'Docker client is required to continue'
  exit 1
fi

ZONE=eu-central-1

aws resource-groups create-group \
    --name DemoEnvironment \
    --resource-query '{"Type":"TAG_FILTERS_1_0", "Query":"{\"ResourceTypeFilters\":[\"AWS::AllSupported\"],\"TagFilters\":[{\"Key\":\"Environment\", \"Values\":[\"Demo\"]}]}"}' || echo "Group exists, continuing"

aws ecs create-cluster --cluster-name demo-cluster --tags key=Environment,value=Demo

ROLEARN=$(aws iam create-role --role-name ecsTaskExecutionRole \
  --assume-role-policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":[\"ecs-tasks.amazonaws.com\"]},\"Action\":[\"sts:AssumeRole\"]}]}" \
  --query "Role.Arn" --output text
  --tags Key=Environment,Value=Demo)

POLICYARN=$(aws iam list-policies --query 'Policies[?PolicyName==`AmazonECSTaskExecutionRolePolicy`].{ARN:Arn}' \
  --output text)
aws iam attach-role-policy --role-name ecsTaskExecutionRole --policy-arn $POLICYARN

#---- networking stuff

VPCID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query "Vpc.VpcId" --output text)
aws ec2 create-tags --resources $VPCID --tags Key=Environment,Value=Demo
SUBNETID=$(aws ec2 create-subnet --vpc-id $VPCID --cidr-block 10.0.1.0/24 \
  --availability-zone "${ZONE}b" \
  --query "Subnet.SubnetId" --output text)
SUBNET2ID=$(aws ec2 create-subnet --vpc-id $VPCID --cidr-block 10.0.2.0/24 \
  --availability-zone "${ZONE}c" \
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

#----------- Simple app

aws ecr create-repository --repository-name simple-app \
  --tags Key=Environment,Value=Demo

SIMPLEAPPREPOURL=$(aws ecr describe-repositories \
  --repository-names simple-app \
  --query "repositories[0].repositoryUri" --output text)

$(aws ecr get-login --region $ZONE --no-include-email)

docker build -t $SIMPLEAPPREPOURL:0.1 static-app/
docker push $SIMPLEAPPREPOURL:0.1

export ROLEARN SIMPLEAPPREPOURL
envsubst < static-app/task-definition.json.tmpl > task-definition.json
TASKREVISION=$(aws ecs register-task-definition --cli-input-json file://task-definition.json \
  --tags key=Environment,value=Demo --query "taskDefinition.revision" --output text)

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

#----------- Intermediate cleanup

aws ecs update-service --service simple-app --cluster demo-cluster --desired-count 0
aws ecs delete-service --service simple-app --cluster demo-cluster
aws ecs wait services-inactive --service simple-app --cluster demo-cluster
aws ecs deregister-task-definition --task-definition simple-app:$TASKREVISION
aws ecr delete-repository --repository-name simple-app --force

#----------- Load balancer

LBARN=$(aws elbv2 create-load-balancer --tags Key=Environment,Value=Demo --name demo-balancer \
  --type application --subnets $SUBNETID $SUBNET2ID --security-groups $SECURITYGROUPID \
  --tags Key=Environment,Value=Demo \
  --query "LoadBalancers[0].LoadBalancerArn" --output text)

TGARN=$(aws elbv2 create-target-group --name hostname-app-tg \
  --protocol HTTP --port 80 --target-type ip --vpc-id $VPCID \
  --query "TargetGroups[0].TargetGroupArn" --output text)

aws elbv2 add-tags --resource-arns $TGARN --tags Key=Environment,Value=Demo

LISTENERARN=$(aws elbv2 create-listener --load-balancer-arn $LBARN --protocol HTTP \
  --port 80 --default-actions Type=forward,TargetGroupArn=$TGARN \
  --query "Listeners[0].ListenerArn" --output text)

aws elbv2 add-tags --resource-arns $TGARN --tags Key=Environment,Value=Demo

aws ecr create-repository --repository-name hostname-app \
  --tags Key=Environment,Value=Demo

HOSTNAMEAPPREPOURL=$(aws ecr describe-repositories \
  --repository-names hostname-app \
  --query "repositories[0].repositoryUri" --output text)

$(aws ecr get-login --region $ZONE --no-include-email)

docker build -t $HOSTNAMEAPPREPOURL:0.1 hostname-app/
docker push $HOSTNAMEAPPREPOURL:0.1

export ROLEARN HOSTNAMEAPPREPOURL
envsubst < hostname-app/task-definition.json.tmpl > task-definition.json

HNTASKREVISION=$(aws ecs register-task-definition --cli-input-json file://task-definition.json \
  --tags key=Environment,value=Demo --query "taskDefinition.revision" --output text)

aws ecs create-service --cluster demo-cluster --service-name hostname-app-service \
  --task-definition hostname-app:HNTASKREVISION --desired-count 2 --launch-type "FARGATE" \
  --scheduling-strategy REPLICA --deployment-controller '{"type": "ECS"}'\
  --deployment-configuration minimumHealthyPercent=100,maximumPercet=200
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETID],securityGroups=[$SECURITYGROUPID],assignPublicIp=\"DISABLED\"}" \
  --load-balancers targetGroupArn=$TGARN,containerName=hostname-app,containerPort=8080 \
  --tags key=Environment,value=Demo

aws ecs wait services-stable --cluster demo-cluster --services simple-app
LBURL=$(aws elbv2 describe-load-balancers --query "LoadBalancers[0].DNSName" --output text)

echo "Load balancer now reachable at $LBURL"
echo "Checkpoint 2, press enter to continue"
read

#----------- Cleanup

aws ecs update-service --service hostname-app-service --cluster demo-cluster --desired-count 0
aws ecs delete-service --service hostname-app-service --cluster demo-cluster
# This takes some time
aws ecs wait services-inactive --service hostname-app-service --cluster demo-cluster

aws ecr delete-repository --repository-name hostname-app --force
aws ecs deregister-task-definition --task-definition hostname-app:$HNTASKREVISION
aws iam detach-role-policy --role-name ecsTaskExecutionRole --policy-arn $POLICYARN
aws iam delete-role --role-name ecsTaskExecutionRole
aws ecs delete-cluster --cluster demo-cluster

aws elbv2 delete-listener --listener-arn $LISTENERARN
aws elbv2 delete-target-group --target-group-arn $TGARN
aws elbv2 delete-load-balancer --load-balancer-arn $LBARN
# If we don't wait for this, deleting the gateway and vpc fail
aws elbv2 wait load-balancers-deleted --load-balancer-arn $LBARN
aws ec2 detach-internet-gateway --internet-gateway-id $GATEWAYID --vpc-id $VPCID
aws ec2 delete-internet-gateway --internet-gateway-id $GATEWAYID
aws ec2 delete-subnet --subnet-id $SUBNETID
aws ec2 delete-subnet --subnet-id $SUBNET2ID
aws ec2 delete-vpc --vpc-id $VPCID

aws resource-groups delete-group --group-name DemoEnvironment
