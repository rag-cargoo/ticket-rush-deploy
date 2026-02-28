variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "Resource name prefix"
  type        = string
  default     = "ticket-rush"
}

variable "environment" {
  description = "Environment label"
  type        = string
  default     = "dev"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.small"
}

variable "key_name" {
  description = "Optional existing EC2 key pair name (blank = no key pair)"
  type        = string
  default     = ""
}

variable "enable_ssh" {
  description = "Whether to open SSH port 22"
  type        = bool
  default     = false
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed for SSH"
  type        = string
  default     = "0.0.0.0/0"
}

variable "root_volume_size" {
  description = "Root EBS volume size (GB)"
  type        = number
  default     = 30
}

variable "instance_profile_name" {
  description = "Optional existing instance profile name"
  type        = string
  default     = ""
}
