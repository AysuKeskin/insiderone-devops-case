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
  default     = "kube-pulse"
}

# GitHub now embeds immutable numeric IDs in the OIDC subject claim
# (owner@ownerID/repo@repoID), so the trust policy has to know them. Read them
# from https://api.github.com/users/<owner> and .../repos/<owner>/<repo>.
variable "github_owner_id" {
  description = "Numeric GitHub owner ID used in the OIDC subject claim."
  type        = string
  default     = "182776874"
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID used in the OIDC subject claim."
  type        = string
  default     = "1247650773"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB. Minikube + image cache need ~10 GB headroom."
  type        = number
  default     = 20
}
