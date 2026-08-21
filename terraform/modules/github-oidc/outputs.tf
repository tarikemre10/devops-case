output "role_arn" {
  description = "GitHub Actions workflow'unda role-to-assume olarak kullanılır."
  value       = aws_iam_role.github_actions.arn
}

output "role_name" {
  description = "IAM rol adı."
  value       = aws_iam_role.github_actions.name
}
