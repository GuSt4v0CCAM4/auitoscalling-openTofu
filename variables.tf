variable "project_id" {
  description = "Google Cloud Project ID"
  type        = string
}

variable "region" {
  description = "Google Cloud region"
  type        = string
  default     = "us-central1"
}

variable "k3s_server_machine_type" {
  description = "Machine type for K3s server (master node)"
  type        = string
  default     = "e2-medium" # 2 vCPUs, 4GB RAM
}

variable "agent_machine_type" {
  description = "Machine type for K3s agents (worker nodes in autoscaling group)"
  type        = string
  default     = "e2-small" # 2 vCPUs, 2GB RAM (upgraded from e2-micro for K3s)
}

variable "min_replicas" {
  description = "Minimum number of instances in autoscaling group"
  type        = number
  default     = 2
}

variable "max_replicas" {
  description = "Maximum number of instances in autoscaling group"
  type        = number
  default     = 5
}

variable "cpu_target" {
  description = "Target CPU utilization for autoscaling (0.0 - 1.0)"
  type        = number
  default     = 0.6
}

variable "enable_auto_deploy" {
  description = "Enable automatic deployment of Coarlumini after infrastructure is ready"
  type        = bool
  default     = true
}

variable "deploy_wait_time" {
  description = "Time to wait (in seconds) for K3s initialization before deploying application"
  type        = number
  default     = 180
}
