#!/bin/bash

# This script is executed after Terraform has successfully created the EKS cluster
# It handles the post-deployment configuration such as setting up the aws-auth configmap

# Update kubeconfig with the new cluster details
echo "Updating kubeconfig with the newly created cluster..."
aws eks --region $(terraform output -raw region) update-kubeconfig --name $(terraform output -raw cluster_name)

# Check if aws-auth configmap exists
echo "Checking for aws-auth configmap in kube-system namespace..."
if kubectl get configmap aws-auth -n kube-system &> /dev/null; then
    echo "aws-auth configmap already exists, updating"
    # Get existing configmap
    kubectl get configmap aws-auth -n kube-system -o yaml > aws-auth.yaml
else
    echo "Creating aws-auth configmap..."
    # Create empty configmap file
    cat > aws-auth.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
EOF
fi

# Get the IAM role ARN for the node group from Terraform output or AWS CLI
NODE_ROLE=$(aws iam list-roles --query "Roles[?contains(RoleName, \`$(terraform output -raw cluster_name)*node*\`)].Arn" --output text)

if [ -z "$NODE_ROLE" ]; then
    echo "Error: Could not find node role ARN for the cluster. Check AWS IAM roles."
    exit 1
fi

echo "Using node role ARN: $NODE_ROLE"

# Update or create aws-auth configmap
cat > aws-auth.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: $NODE_ROLE
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
EOF

# Apply aws-auth configmap
kubectl apply -f aws-auth.yaml
rm aws-auth.yaml

# Check if the aws-auth configmap was applied successfully
if kubectl get configmap aws-auth -n kube-system &> /dev/null; then
    echo "Successfully configured aws-auth configmap"
else
    echo "Failed to configure aws-auth configmap"
    exit 1
fi

# Output cluster information
echo "====== EKS Cluster Deployment Complete ======"
echo "Cluster Name: $(terraform output -raw cluster_name)"
echo "Cluster Endpoint: $(terraform output -raw cluster_endpoint)"
echo "Region: $(terraform output -raw region)"
echo "=============================================="
