#!/bin/bash

# Update kubeconfig
echo "Updating kubeconfig..."
aws eks --region $(terraform -chdir=./Terraform output -raw region) update-kubeconfig --name $(terraform -chdir=./Terraform output -raw cluster_name)

# Check if aws-auth configmap exists
echo "Checking for aws-auth configmap in kube-system namespace..."
if kubectl get configmap aws-auth -n kube-system &> /dev/null; then
    echo "aws-auth configmap already exists, updating"
    
    # Fetch node role ARN directly from AWS
    CLUSTER_NAME=$(terraform -chdir=./Terraform output -raw cluster_name)
    NODE_GROUP_NAME="${CLUSTER_NAME}-eks-node-group-default"
    
    # Get the node group's role ARN
    NODE_ROLE_ARN=$(aws eks describe-nodegroup --cluster-name ${CLUSTER_NAME} --nodegroup-name ${NODE_GROUP_NAME} --query "nodegroup.nodeRole" --output text)
    
    if [ -z "$NODE_ROLE_ARN" ]; then
        echo "Could not fetch node role ARN from EKS API. Using alternative method..."
        # Alternative method - get all node groups and try to find ours
        NODE_GROUPS=$(aws eks list-nodegroups --cluster-name ${CLUSTER_NAME} --query "nodegroups" --output text)
        
        for NG in $NODE_GROUPS; do
            NODE_ROLE_ARN=$(aws eks describe-nodegroup --cluster-name ${CLUSTER_NAME} --nodegroup-name ${NG} --query "nodegroup.nodeRole" --output text)
            if [ ! -z "$NODE_ROLE_ARN" ]; then
                echo "Found role ARN for nodegroup ${NG}: ${NODE_ROLE_ARN}"
                break
            fi
        done
    fi
    
    if [ -z "$NODE_ROLE_ARN" ]; then
        echo "Error: Could not find node role ARN for the cluster. Check AWS IAM roles."
        echo "Creating a basic aws-auth configmap..."
        
        # Create a basic aws-auth configmap without specifying roles
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    []
EOF
    else
        # Update the aws-auth configmap with the role
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
else
    echo "aws-auth configmap does not exist, creating..."
    # Rest of your existing code for creating the configmap...
fi

echo "Post-deployment configuration completed!"
