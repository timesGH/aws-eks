#!/bin/bash
set -e

REGION="$1"
CLUSTER_NAME="$2"

echo "Starting cleanup for region $REGION and cluster $CLUSTER_NAME"

# Check if the cluster exists
if ! aws eks describe-cluster --name $CLUSTER_NAME --region $REGION &>/dev/null; then
  echo "Cluster $CLUSTER_NAME does not exist in region $REGION. Skipping EKS cleanup."
else
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

  # 3. Find and delete any load balancers associated with the cluster
  echo "Checking for Load Balancers associated with EKS..."
  # Get cluster tag to identify resources
  CLUSTER_TAG="kubernetes.io/cluster/$CLUSTER_NAME"
  
  # Find load balancers that might be created by Kubernetes
  LB_ARNS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerArn" --output text --region $REGION)
  
  if [ ! -z "$LB_ARNS" ]; then
    for LB in $LB_ARNS; do
      # Check if this LB is associated with our cluster
      LB_TAGS=$(aws elbv2 describe-tags --resource-arns $LB --region $REGION --query "TagDescriptions[0].Tags[?Key=='$CLUSTER_TAG']" --output text)
      
      if [ ! -z "$LB_TAGS" ]; then
        echo "Deleting EKS-associated Load Balancer $LB..."
        aws elbv2 delete-load-balancer --load-balancer-arn $LB --region $REGION
      fi
    done
    
    echo "Waiting for Load Balancers to delete (30 seconds)..."
    sleep 30
  fi

  # 4. Delete the EKS cluster
  echo "Deleting EKS cluster $CLUSTER_NAME..."
  aws eks delete-cluster --name $CLUSTER_NAME --region $REGION
  echo "Waiting for EKS cluster $CLUSTER_NAME to delete..."
  aws eks wait cluster-deleted --name $CLUSTER_NAME --region $REGION

  # Wait for AWS resources to clean up
  echo "Waiting 2 minutes for AWS to clean up EKS resources..."
  sleep 120
fi

# Find VPC associated with the cluster (by tag)
echo "Finding VPC associated with the cluster..."
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" --query "Vpcs[0].VpcId" --output text --region $REGION)

# If no VPC found by tag, try by name
if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
  echo "No VPC found by cluster tag. Trying by name..."
  VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*${CLUSTER_NAME}*" --query "Vpcs[0].VpcId" --output text --region $REGION)
fi

if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
  echo "No VPC found for cluster $CLUSTER_NAME. Skipping VPC cleanup."
  exit 0
fi

echo "Found VPC: $VPC_ID"

# 5. Find and delete any NAT gateways in the VPC
echo "Checking for NAT Gateways..."
NAT_GATEWAY_IDS=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text --region $REGION)

if [ ! -z "$NAT_GATEWAY_IDS" ]; then
  echo "Found NAT Gateways: $NAT_GATEWAY_IDS"
  for NGW in $NAT_GATEWAY_IDS; do
    echo "Deleting NAT Gateway $NGW..."
    aws ec2 delete-nat-gateway --nat-gateway-id $NGW --region $REGION
  done
  
  echo "Waiting for NAT Gateways to delete (60 seconds)..."
  sleep 60
fi

# 6. Find and delete any route tables that use the internet gateway
echo "Finding Internet Gateway..."
IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[0].InternetGatewayId" --output text --region $REGION)

if [ "$IGW_ID" != "None" ] && [ ! -z "$IGW_ID" ]; then
  echo "Found Internet Gateway: $IGW_ID"
  
  echo "Updating route tables..."
  ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[].RouteTableId' --output text --region $REGION)
  
  if [ ! -z "$ROUTE_TABLE_IDS" ]; then
    for RT in $ROUTE_TABLE_IDS; do
      echo "Checking routes in route table $RT..."
      # Check if this route table has a route to the internet gateway
      ROUTES=$(aws ec2 describe-route-tables --route-table-ids $RT --query "RouteTables[0].Routes[?GatewayId=='$IGW_ID']" --output text --region $REGION)
      
      if [ ! -z "$ROUTES" ]; then
        echo "Deleting routes to Internet Gateway in $RT..."
        aws ec2 delete-route --route-table-id $RT --destination-cidr-block 0.0.0.0/0 --region $REGION || true
      fi
    done
  fi
  
  # Detach and delete the internet gateway
  echo "Detaching Internet Gateway $IGW_ID from VPC $VPC_ID..."
  aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $REGION || true
  
  echo "Deleting Internet Gateway $IGW_ID..."
  aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID --region $REGION || true
fi

# Wait to ensure all dependencies are deleted
echo "Waiting 30 seconds for resources to clean up..."
sleep 30

# 7. Delete all the subnets
echo "Deleting subnets..."
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text --region $REGION)

if [ ! -z "$SUBNET_IDS" ]; then
  for SUBNET_ID in $SUBNET_IDS; do
    echo "Deleting subnet $SUBNET_ID..."
    aws ec2 delete-subnet --subnet-id $SUBNET_ID --region $REGION || true
  done
fi

# 8. Delete VPC endpoints
echo "Deleting VPC endpoints..."
VPC_ENDPOINT_IDS=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --query "VpcEndpoints[].VpcEndpointId" --output text --region $REGION)

if [ ! -z "$VPC_ENDPOINT_IDS" ]; then
  echo "Deleting VPC endpoints: $VPC_ENDPOINT_IDS"
  aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $VPC_ENDPOINT_IDS --region $REGION || true
  echo "Waiting 30 seconds for VPC endpoints to delete..."
  sleep 30
fi

# 9. Delete security groups
echo "Deleting security groups..."
SEC_GROUPS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text --region $REGION)

if [ ! -z "$SEC_GROUPS" ]; then
  for SG in $SEC_GROUPS; do
    echo "Deleting security group $SG..."
    aws ec2 delete-security-group --group-id $SG --region $REGION || true
  done
fi

# 10. Finally, delete the VPC
echo "Deleting VPC $VPC_ID..."
aws ec2 delete-vpc --vpc-id $VPC_ID --region $REGION || true

echo "Cleanup completed."
