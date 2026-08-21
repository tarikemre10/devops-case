variable "project" {
  description = "Kaynak adlarında ve etiketlerde kullanılan proje öneki."
  type        = string
  default     = "mern-devops-case"
}

variable "region" {
  description = "AWS bölgesi. State bucket'ı ana stack ile aynı bölgede durur."
  type        = string
  default     = "eu-central-1"
}
