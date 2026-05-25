variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "eu-north-1"
}

variable "instance_type" {
  description = "EC2 instance type. t3.medium (4 GiB) is the smallest size that runs minikube + ingress + metrics-server + the app without OOM."
  type        = string
  default     = "t3.medium"
}

variable "github_owner" {
  description = "GitHub owner for the OIDC trust policy and user-data git clone."
  type        = string
  default     = "AysuKeskin"
}

variable "github_repo" {
  description = "GitHub repository name for the OIDC trust policy and user-data git clone."
  type        = string
  default     = "insiderone-devops-case"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB. Minikube + image cache need ~10 GB headroom."
  type        = number
  default     = 20
}
