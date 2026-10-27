output "alb_url" {
  value = "http://${aws_lb.main.dns_name}"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "ecs_cluster" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service" {
  value = aws_ecs_service.app.name
}

output "gh_plan_role_arn" {
  value = aws_iam_role.gh_plan.arn
}

output "gh_infra_apply_role_arn" {
  value = aws_iam_role.gh_infra_apply.arn
}

output "gh_app_deploy_role_arn" {
  value = aws_iam_role.gh_app_deploy.arn
}
