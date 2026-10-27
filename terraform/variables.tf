variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "project" {
  type    = string
  default = "ecs-supply-chain"
}

variable "environment" {
  type    = string
  default = "demo"
}

variable "github_oidc_repo" {
  description = "Repository as it appears in the OIDC sub claim: owner@owner_id/name@repo_id"
  type        = string
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "alarm_5xx_threshold" {
  description = "Target 5xx responses per minute that trigger rollback"
  type        = number
  default     = 10
}

variable "alarm_response_time_threshold" {
  description = "Average target response time in seconds that triggers rollback"
  type        = number
  default     = 1
}
