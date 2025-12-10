variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "lab-6-5-secure-webapp"
  type        = string
  default     = "lab-6-5-secure-webapp"
}

variable "app_secret_value" {
  description = "DB password"
  type        = string
  sensitive   = true
}
