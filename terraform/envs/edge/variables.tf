variable "project" {
  type    = string
  default = "mern-devops-case"
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "ingress_stack" {
  description = "ALB Controller'ın koyduğu stack tag'i: <namespace>/<ingress-adı>."
  type        = string
  default     = "mern/mern-ingress"
}
