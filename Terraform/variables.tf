variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_version" {
  description = "Kubernetes cluster version"
  type        = string
  default     = "1.28"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "my_eks_cluster"
}

variable "instance_types" {
  description = "EC2 instances used for K8s nodes"
  type        = list(string)
  default     = ["t2.small"]
}

variable "vpc_cidr" {
  description = "The CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "cluster_min_size" {
  description = "K8s Cluster minimum size"
  type        = number
  default     = 1
}

variable "cluster_max_size" {
  description = "K8s Cluster maximum size"
  type        = number
  default     = 3
}

variable "cluster_desired_size" {
  description = "K8s Cluster desired size"
  type        = number
  default     = 2
}

variable "app_name" {
  description = "Name of the application to be deployed in EKS"
  type        = string
  default     = "nodejs-app"
}

variable "terraform_organization" {
  description = "Terraform Cloud organization name"
  type        = string
  default     = "Honours"
}

variable "terraform_workspace" {
  description = "Terraform Cloud workspace name"
  type        = string
  default     = "eks-demo"
}

variable "allowed_cidr_blocks" {
  description = "List of CIDR blocks that can access the EKS cluster endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
