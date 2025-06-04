variable "aws_access_key" {
  description = "AWS access key"
  type        = string
  sensitive   = true
}

variable "aws_secret_key" {
  description = "AWS secret key"
  type        = string
  sensitive   = true
} 

variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name of the project, used for resource naming"
  type        = string
  default     = "n8n-ollama"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "instance_type" {
  description = "Instance type to use for EC2 instance"
  type        = string
  default     = "g4dn.2xlarge"
}

variable "key_pair_name" {
  description = "Name of the AWS key pair to use for EC2 instance"
  type        = string
  default     = "private_key_name"
}

variable "root_volume_size" {
  description = "Size of the root volume in GB"
  type        = number
  default     = 300
} 