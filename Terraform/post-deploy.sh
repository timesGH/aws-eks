#!/bin/bash
set -e

# Get outputs from Terraform
echo "Getting Terraform outputs..."
cd Terraform
CLUSTER_NAME=$(terraform output -raw cluster_name)
REGION=$(terraform output -raw region)
cd ..

# Update kubeconfig
echo "Updating kubeconfig..."
aws eks update-kubeconfig --region ${REGION} --name ${CLUSTER_NAME}

# Check for nodegroups
echo "Checking for nodegroups..."
NODE_GROUPS=$(aws eks list-nodegroups --cluster-name ${CLUSTER_NAME} --region ${REGION} --query 'nodegroups[*]' --output text)

if [ -z "$NODE_GROUPS" ]; then
  echo "No nodegroups found. Skipping aws-auth configuration."
  exit 0
fi

# Get the first nodegroup
NODE_GROUP=$(echo $NODE_GROUPS | awk '{print $1}')
echo "Found nodegroup: ${NODE_GROUP}"

# Get the IAM role ARN for the nodegroup
NODE_ROLE_ARN=$(aws eks describe-nodegroup --cluster-name ${CLUSTER_NAME} --nodegroup-name ${NODE_GROUP} --region ${REGION} --query 'nodegroup.nodeRole' --output text)

if [ -z "$NODE_ROLE_ARN" ]; then
  echo "Could not determine node role ARN. Skipping aws-auth configuration."
  exit 0
fi

echo "Node Role ARN: ${NODE_ROLE_ARN}"

# Check if aws-auth configmap exists
echo "Checking for aws-auth configmap..."
if kubectl get configmap aws-auth -n kube-system &> /dev/null; then
  echo "aws-auth configmap exists, updating..."
  
  # Get current configmap
  kubectl get configmap aws-auth -n kube-system -o yaml > aws-auth.yaml
  
  # Check if the role is already in the configmap
  if grep -q "${NODE_ROLE_ARN}" aws-auth.yaml; then
    echo "Role already exists in aws-auth configmap. No changes needed."
    rm aws-auth.yaml
    exit 0
  fi
  
  # Update the configmap
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: ${NODE_ROLE_ARN}
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
EOF
else
  echo "aws-auth configmap does not exist, creating..."
  # Create the configmap
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: ${NODE_ROLE_ARN}
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
EOF
fi

echo "Waiting for nodes to become ready..."
kubectl wait --for=condition=ready nodes --all --timeout=5m

echo "Post-deployment configuration completed!"
