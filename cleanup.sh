#!/bin/bash
set -e

REGION="$1"
CLUSTER_NAME="$2"

echo "Starting cleanup for region $REGION and cluster $CLUSTER_NAME"

# Find VPC associated with the EKS cluster
echo "Finding VPC for EKS cluster $CLUSTER_NAME..."
CLUSTER_VPC_CONFIG=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query "cluster.resourcesVpcConfig" --output json 2>/dev/null || echo '{"vpcId": ""}')
VPC_ID=$(echo $CLUSTER_VPC_CONFIG | jq -r '.vpcId')

if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "null" ] || [ "$VPC_ID" == "" ]; then
  echo "Could not find VPC for cluster $CLUSTER_NAME. Trying to identify VPC from tags..."
  # Try to find VPC by tags
  VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*${CLUSTER_NAME}*" --query "Vpcs[0].VpcId" --output text --region $REGION)
fi

if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "null" ] || [ "$VPC_ID" == "None" ]; then
  echo "No VPC found for cluster $CLUSTER_NAME. Skipping cleanup."
  exit 0
fi

echo "Found VPC: $VPC_ID"

# Find subnets in the VPC
echo "Finding subnets in VPC $VPC_ID..."
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text --region $REGION)
echo "Found subnets: $SUBNET_IDS"

# Find Internet Gateway for the VPC
echo "Finding Internet Gateway for VPC $VPC_ID..."
IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[0].InternetGatewayId" --output text --region $REGION)
echo "Found Internet Gateway: $IGW_ID"

# 1. Delete any EKS managed nodegroups
echo "Checking for EKS nodegroups..."
NODEGROUPS=$(aws eks list-nodegroups --cluster-name $CLUSTER_NAME --region $REGION --query 'nodegroups[*]' --output text 2>/dev/null || echo "")
if [ ! -z "$NODEGROUPS" ]; then
  echo "Found nodegroups: $NODEGROUPS"
  for NG in $NODEGROUPS; do
    echo "Deleting nodegroup $NG..."
    aws eks delete-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name $NG --region $REGION
    echo "Waiting for nodegroup $NG to delete..."
    aws eks wait nodegroup-deleted --cluster-name $CLUSTER_NAME --nodegroup-name $NG --region $REGION
  done
fi

# 2. Delete any EKS fargate profiles
echo "Checking for EKS fargate profiles..."
FARGATE_PROFILES=$(aws eks list-fargate-profiles --cluster-name $CLUSTER_NAME --region $REGION --query 'fargateProfileNames[*]' --output text 2>/dev/null || echo "")
if [ ! -z "$FARGATE_PROFILES" ]; then
  echo "Found fargate profiles: $FARGATE_PROFILES"
  for FP in $FARGATE_PROFILES; do
    echo "Deleting fargate profile $FP..."
    aws eks delete-fargate-profile --cluster-name $CLUSTER_NAME --fargate-profile-name $FP --region $REGION
    echo "Waiting for fargate profile $FP to delete..."
    aws eks wait fargate-profile-deleted --cluster-name $CLUSTER_NAME --fargate-profile-name $FP --region $REGION
  done
fi

# 3. Delete the EKS cluster
echo "Deleting EKS cluster $CLUSTER_NAME..."
aws eks delete-cluster --name $CLUSTER_NAME --region $REGION 2>/dev/null || true
echo "Waiting for EKS cluster $CLUSTER_NAME to delete..."
aws eks wait cluster-deleted --name $CLUSTER_NAME --region $REGION 2>/dev/null || true

# 4. Find and delete any NAT gateways in the VPC
echo "Checking for NAT Gateways..."
NAT_GATEWAY_IDS=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text --region $REGION)

if [ ! -z "$NAT_GATEWAY_IDS" ]; then
  echo "Found NAT Gateways: $NAT_GATEWAY_IDS"
  for NGW in $NAT_GATEWAY_IDS; do
    echo "Deleting NAT Gateway $NGW..."
    aws ec2 delete-nat-gateway --nat-gateway-id $NGW --region $REGION
    echo "Waiting for NAT Gateway $NGW to delete..."
    aws ec2 wait nat-gateway-deleted --nat-gateway-ids $NGW --region $REGION
  done
fi

# 5. Find and delete any load balancers in the VPC
echo "Checking for Load Balancers..."
LB_ARNS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text --region $REGION)

if [ ! -z "$LB_ARNS" ]; then
  echo "Found Load Balancers: $LB_ARNS"
  for LB in $LB_ARNS; do
    echo "Deleting Load Balancer $LB..."
    aws elbv2 delete-load-balancer --load-balancer-arn $LB --region $REGION
  done
  
  echo "Waiting for Load Balancers to delete (30 seconds)..."
  sleep 30
fi

# 6. Find and terminate EC2 instances in these subnets
for SUBNET_ID in $SUBNET_IDS; do
  echo "Checking for EC2 instances in subnet $SUBNET_ID..."
  INSTANCE_IDS=$(aws ec2 describe-instances --filters "Name=subnet-id,Values=$SUBNET_ID" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text --region $REGION)
  
  if [ ! -z "$INSTANCE_IDS" ]; then
    echo "Found instances: $INSTANCE_IDS"
    echo "Terminating instances in subnet $SUBNET_ID: $INSTANCE_IDS"
    aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region $REGION
    
    echo "Waiting for instances to terminate..."
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region $REGION
  fi
done

# 7. Find and delete Network Interfaces in these subnets
for SUBNET_ID in $SUBNET_IDS; do
  echo "Checking for Network Interfaces in subnet $SUBNET_ID..."
  ENI_IDS=$(aws ec2 describe-network-interfaces --filters "Name=subnet-id,Values=$SUBNET_ID" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text --region $REGION)
  
  if [ ! -z "$ENI_IDS" ]; then
    echo "Found network interfaces: $ENI_IDS"
    for ENI in $ENI_IDS; do
      ATTACHMENT_ID=$(aws ec2 describe-network-interfaces --network-interface-ids $ENI --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text --region $REGION)
      
      if [ "$ATTACHMENT_ID" != "None" ] && [ ! -z "$ATTACHMENT_ID" ]; then
        echo "Detaching $ENI with attachment $ATTACHMENT_ID"
        aws ec2 detach-network-interface --attachment-id $ATTACHMENT_ID --force --region $REGION
        sleep 5
      fi
      
      echo "Deleting network interface $ENI"
      aws ec2 delete-network-interface --network-interface-id $ENI --region $REGION || true
    done
  fi
done

# 8. Find and update route tables that use the internet gateway
if [ "$IGW_ID" != "None" ] && [ ! -z "$IGW_ID" ]; then
  echo "Checking for routes through Internet Gateway..."
  ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[].RouteTableId' --output text --region $REGION)

  if [ ! -z "$ROUTE_TABLE_IDS" ]; then
    echo "Found route tables: $ROUTE_TABLE_IDS"
    for RT in $ROUTE_TABLE_IDS; do
      echo "Removing Internet Gateway routes from $RT"
      aws ec2 delete-route --route-table-id $RT --destination-cidr-block 0.0.0.0/0 --region $REGION || true
    done
  fi

  # 9. Detach internet gateway from VPC
  echo "Detaching Internet Gateway $IGW_ID from VPC $VPC_ID"
  aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $REGION || true

  # 10. Delete the internet gateway
  echo "Deleting Internet Gateway $IGW_ID"
  aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID --region $REGION || true
fi

# 11. Delete subnets
echo "Deleting Subnets..."
for SUBNET_ID in $SUBNET_IDS; do
  echo "Deleting Subnet $SUBNET_ID"
  aws ec2 delete-subnet --subnet-id $SUBNET_ID --region $REGION || true
done

# 12. Find and delete security groups (except default)
echo "Deleting Security Groups..."
SEC_GROUPS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text --region $REGION)
for SG in $SEC_GROUPS; do
  echo "Deleting Security Group $SG"
  aws ec2 delete-security-group --group-id $SG --region $REGION || true
done

# 13. Find and delete any VPC endpoints
echo "Checking for VPC Endpoints..."
VPC_ENDPOINT_IDS=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --query 'VpcEndpoints[].VpcEndpointId' --output text --region $REGION)
if [ ! -z "$VPC_ENDPOINT_IDS" ]; then
  echo "Found VPC endpoints: $VPC_ENDPOINT_IDS"
  aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $VPC_ENDPOINT_IDS --region $REGION || true
fi

# 14. Delete the VPC
echo "Deleting VPC $VPC_ID"
aws ec2 delete-vpc --vpc-id $VPC_ID --region $REGION || true

echo "Cleanup complete. Resources may still be in the process of deletion."
