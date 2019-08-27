set -e

aws ec2 import-key-pair --key-name brand-new-key --public-key-material file://~/.ssh/id_rsa.pub

aws resource-groups create-group \
    --name DemoEnvironment \
    --resource-query '{"Type":"TAG_FILTERS_1_0", "Query":"{\"ResourceTypeFilters\":[\"AWS::AllSupported\"],\"TagFilters\":[{\"Key\":\"Environment\", \"Values\":[\"Demo\"]}]}"}'

VPCID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query "Vpc.VpcId" --output text)
aws ec2 create-tags --resources $VPCID --tags Key=Environment,Value=Demo

SUBNETID=$(aws ec2 create-subnet --vpc-id $VPCID --cidr-block 10.0.1.0/24 \
  --query "Subnet.SubnetId" --output text)
aws ec2 create-tags --resources $SUBNETID --tags Key=Environment,Value=Demo

AMIID=$(aws ec2 describe-images --filters "Name=root-device-type,Values=ebs" \
  "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server-*" \
  "Name=architecture,Values=x86_64" \
  --query "reverse(sort_by(Images, &CreationDate)) | [?! ProductCodes] | [0].ImageId" \
  --output text)

aws ec2 run-instances --image-id $AMIID --count 1 \
    --instance-type t2.micro --key-name brand-new-key \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Environment,Value=Demo}]' \
    --subnet-id $SUBNETID
INSTANCEID=$(aws ec2 describe-instances --filter "Name=tag:Environment,Values=Demo" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)
aws ec2 wait instance-running --instance-ids $INSTANCEID
echo "Instance $INSTANCEID created and running"

echo "Checkpoint 1, press enter to continue"
read

GATEWAYID=$(aws ec2 create-internet-gateway --query "InternetGateway.InternetGatewayId" \
  --output text)
aws ec2 create-tags --resources $GATEWAYID --tags Key=Environment,Value=Demo
aws ec2 attach-internet-gateway --vpc-id $VPCID --internet-gateway-id $GATEWAYID

ROUTETABLEID=$(aws ec2 describe-route-tables --filter "Name=vpc-id,Values=$VPCID" \
  --query "RouteTables[0].RouteTableId" --output text)

aws ec2 create-tags --resources $ROUTETABLEID --tags Key=Environment,Value=Demo
aws ec2 create-route --route-table-id $ROUTETABLEID --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $GATEWAYID

aws ec2 modify-subnet-attribute --subnet-id $SUBNETID --map-public-ip-on-launch
aws ec2 modify-vpc-attribute --vpc-id $VPCID --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPCID --enable-dns-support

aws ec2 terminate-instances --instance-ids $INSTANCEID

INSTANCEID=$(aws ec2 run-instances --image-id $AMIID --count 1 \
    --instance-type t2.micro --key-name key-at-work \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Environment,Value=Demo}]' \
    --subnet-id $SUBNETID --query "Instances[0].InstanceId" --output text)
aws ec2 wait instance-running --instance-ids $INSTANCEID
echo "Instance $INSTANCEID created and running"

IPADDRESS=$(aws ec2 describe-instances --instance-ids $INSTANCEID \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
PUBLICDNS=$(aws ec2 describe-instances --instance-ids $INSTANCEID \
  --query "Reservations[0].Instances[0].PublicDnsName" --output text)

echo "Instance reachable at IP $IPADDRESS or at $PUBLICDNS"

echo "Checkpoint 2, press enter to continue"
read

SECURITYGROUPID=$(aws ec2 describe-security-groups \
  --filters Name=vpc-id,Values=$VPCID \
  --query "SecurityGroups[0].GroupId" --output text)
aws ec2 authorize-security-group-ingress --group-id $SECURITYGROUPID \
  --protocol tcp --port 22 --cidr 0.0.0.0/0
echo "Security group reconfigured, you can now run ssh ubuntu@$PUBLICDNS"
echo "Checkpoint 3, press enter to clean up"
read

echo "Cleaning up"

aws ec2 terminate-instances --instance-ids $INSTANCEID
aws ec2 delete-key-pair --key-name brand-new-key
aws ec2 detach-internet-gateway --internet-gateway-id $GATEWAYID --vpc-id $VPCID
aws ec2 delete-internet-gateway --internet-gateway-id $GATEWAYID
aws ec2 delete-subnet --subnet-id $SUBNETID
aws ec2 delete-vpc --vpc-id $VPCID
aws resource-groups delete-group --group-name DemoEnvironment
