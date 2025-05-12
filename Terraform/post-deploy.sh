#!/bin/bash

# Update kubeconfig
echo "Updating kubeconfig..."
aws eks --region $(terraform output -raw region) update-kubeconfig --name $(terraform output -raw cluster_name)

# Check if aws-auth configmap exists
echo "Checking aws-auth configmap..."
if kubectl get configmap aws-auth -n kube-system &> /dev/null; then
    echo "aws-auth configmap already exists"
else
    echo "Creating aws-auth configmap..."
    # Get the IAM role ARN for the node group
    NODE_ROLE_ARN=$(aws iam get-role --role-name $(terraform output -raw cluster_name)-eks-node-group-default-role --query 'Role.Arn' --output text)
    
    # Create aws-auth configmap
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: $NODE_ROLE_ARN
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
EOF
fi

echo "Post-deployment configuration completed!"
