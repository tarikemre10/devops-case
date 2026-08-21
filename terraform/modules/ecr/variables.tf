variable "project" {
  description = "Repo adlarında namespace olarak kullanılır: <project>/<name>."
  type        = string
}

variable "repository_names" {
  description = "Oluşturulacak repo adları."
  type        = list(string)
}

variable "keep_last_images" {
  description = "Repo başına saklanacak imaj sayısı."
  type        = number
  default     = 10
}

variable "force_delete" {
  description = "İçinde imaj olsa bile repo silinebilsin mi (case temizliği için)."
  type        = bool
  default     = true
}
