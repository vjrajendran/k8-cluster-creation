variable "region" {
  description = "AWS region (lab sandboxes are usually locked to us-east-1)"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use. Leave null to use env vars."
  type        = string
  default     = null
}

variable "master_instance_type" {
  description = "Control plane needs >= 2 vCPU and ~2 GB RAM for kubeadm preflight"
  type        = string
  default     = "t3.medium"
}

variable "worker_instance_type" {
  type    = string
  default = "t3.small"
}

variable "root_volume_size" {
  type    = number
  default = 20
}

variable "ssh_cidr" {
  description = "CIDR allowed to SSH to the nodes. Empty = auto-detect your current public IP."
  type        = string
  default     = ""
}

variable "additional_ssh_cidrs" {
  description = "Additional source CIDRs allowed to SSH to the nodes, such as a developer's public IP."
  type        = list(string)
  default     = []
}

variable "repo_url" {
  type    = string
  default = "https://github.com/rvinodrajendran/k8-cluster-automation.git"
}

variable "repo_branch" {
  type    = string
  default = "main"
}

variable "run_deploy" {
  description = "Set false to only create the instances and skip the bootstrap"
  type        = bool
  default     = true
}
