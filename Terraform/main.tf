terraform {
  backend "remote" {
    # The name of your Terraform Cloud organization.
    organization = "YOUR_ORGANIZATION_NAME"

    # The name of the Terraform Cloud workspace to store Terraform state files in.
    workspaces {
      name = "eks-demo"
    }
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = true

  vpc_cidr = var.vpc_cidr
  
  # EKS Managed Node Group(s)
  eks_managed_node_groups = {
    default = {
      min_size       = var.cluster_min_size
      max_size       = var.cluster_max_size
      desired_size   = var.cluster_desired_size
      instance_types = var.instance_types
    }
  }

  # aws-auth configmap
  manage_aws_auth_configmap = true

  tags = {
    Environment = "dev"
    Project     = "eks-demo"
  }
}
