#!/bin/bash

# This script should be executed after Terraform has successfully created the EKS cluster
# It handles the post-deployment configuration such as setting up the aws-auth configmap

# Update kubeconfig with the new cluster details
echo "Updating kubeconfig with the newly created cluster..."
aws eks --region $(terraform output -raw region) update-kubeconfig --name $(terraform output -raw cluster_name)

# Check if aws-auth configmap exists
echo "Checking for aws-auth configmap in kube-system namespace..."
if kubectl get configmap aws-auth -n kube-system &> /dev/null; then
    echo "aws-auth configmap already exists, skipping creation"
else
    echo "Creating aws-auth configmap..."
    
    # Get the IAM role ARN for the node group from Terraform output
    NODE_ROLE=$(aws iam list-roles --query "Roles[?contains(RoleName, \`$(terraform output -raw cluster_name)*node*\`)].Arn" --output text)
    
    if [ -z "$NODE_ROLE" ]; then
        echo "Error: Could not find node role ARN for the cluster. Check AWS IAM roles."
        exit 1
    fi
    
    echo "Using node role ARN: $NODE_ROLE"
    
    # Create the aws-auth configmap
    cat <<EOF | kubectl apply -f -
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
fi

# Check if the aws-auth configmap was applied successfully
if kubectl get configmap aws-auth -n kube-system &> /dev/null; then
    echo "Successfully configured aws-auth configmap"
else
    echo "Failed to configure aws-auth configmap"
    exit 1
fi

# Create an ECR repository if it doesn't exist
REPO_NAME=$(basename $(git rev-parse --show-toplevel))
echo "Creating ECR repository '$REPO_NAME' if it doesn't exist..."
aws ecr describe-repositories --repository-names "$REPO_NAME" > /dev/null 2>&1 || aws ecr create-repository --repository-name "$REPO_NAME"

# Output cluster information
echo "====== EKS Cluster Deployment Complete ======"
echo "Cluster Name: $(terraform output -raw cluster_name)"
echo "Cluster Endpoint: $(terraform output -raw cluster_endpoint)"
echo "Region: $(terraform output -raw region)"
echo "=============================================="
echo "To deploy your application, run the deploy-nodejs-app.yml workflow in GitHub Actions"
echo "=============================================="
