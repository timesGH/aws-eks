terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.10"
    }
  }
  backend "remote" {
    # The name of your Terraform Cloud organization.
    organization = "Honours"

    # The name of the Terraform Cloud workspace to store Terraform state files in.
    workspaces {
      name = "eks-demo"
    }
  }
}

# Adding the AWS provider configuration
provider "aws" {
  region = var.region
}

# Get EKS cluster authentication token
data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}

# Configure Kubernetes provider with EKS details
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = ["${var.region}a", "${var.region}b", "${var.region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = false
  one_nat_gateway_per_az = true
  enable_dns_hostnames = true

  # Tags required by EKS
  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }

  tags = {
    Environment = "dev"
    Project     = "eks-demo"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.allowed_cidr_blocks
  cluster_endpoint_private_access      = true

  # Use the VPC created above
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
  
  # EKS Managed Node Group(s)
  eks_managed_node_groups = {
    default = {
      min_size       = var.cluster_min_size
      max_size       = var.cluster_max_size
      desired_size   = var.cluster_desired_size
      instance_types = var.instance_types
    }
  }

  # aws-auth configmap management is handled differently in v20+

  tags = {
    Environment = "dev"
    Project     = "eks-demo"
  }
}

# Create ECR repository for application images
resource "aws_ecr_repository" "app_repository" {
  name                 = var.app_name
  image_tag_mutability = "MUTABLE"
  
  image_scanning_configuration {
    scan_on_push = true
  }
  
  tags = {
    Environment = "dev"
    Project     = "eks-demo"
  }
}
