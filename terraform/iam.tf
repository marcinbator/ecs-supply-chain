data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  ecr_repository_arn   = aws_ecr_repository.app.arn
  ecs_service_arn      = "arn:aws:ecs:${var.region}:${local.account_id}:service/${aws_ecs_cluster.main.name}/${local.name}"
  project_role_arn     = "arn:aws:iam::${local.account_id}:role/${local.name}-*"
  read_only_policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
  ecs_lb_policy_arn    = "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForLoadBalancers"
}

data "aws_iam_policy_document" "github_trust" {
  for_each = {
    plan        = "repo:${var.github_repo}:pull_request"
    infra-apply = "repo:${var.github_repo}:environment:infra"
    app-deploy  = "repo:${var.github_repo}:ref:refs/heads/main"
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [each.value]
    }
  }
}

# gh-plan: terraform plan on pull requests

resource "aws_iam_role" "gh_plan" {
  name               = "${local.name}-gh-plan"
  assume_role_policy = data.aws_iam_policy_document.github_trust["plan"].json
}

resource "aws_iam_role_policy_attachment" "gh_plan_read_only" {
  role       = aws_iam_role.gh_plan.name
  policy_arn = local.read_only_policy_arn
}

data "aws_iam_policy_document" "gh_plan" {
  statement {
    sid       = "StateLock"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.state_bucket}/demo/terraform.tfstate.tflock"]
  }
}

resource "aws_iam_role_policy" "gh_plan" {
  name   = "state-lock"
  role   = aws_iam_role.gh_plan.id
  policy = data.aws_iam_policy_document.gh_plan.json
}

# gh-infra-apply: terraform apply on main through the "infra" environment

resource "aws_iam_role" "gh_infra_apply" {
  name               = "${local.name}-gh-infra-apply"
  assume_role_policy = data.aws_iam_policy_document.github_trust["infra-apply"].json
}

resource "aws_iam_role_policy_attachment" "gh_infra_apply_read_only" {
  role       = aws_iam_role.gh_infra_apply.name
  policy_arn = local.read_only_policy_arn
}

data "aws_iam_policy_document" "gh_infra_apply" {
  # VPC, ELB and ECS resource ARNs are generated on creation, so these are
  # limited to the project region instead of specific ARNs.
  statement {
    sid = "RegionalServices"
    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
      "ecs:*",
      "cloudwatch:*",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "Ecr"
    actions   = ["ecr:*"]
    resources = ["arn:aws:ecr:${var.region}:${local.account_id}:repository/${local.name}"]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:*"]
    resources = ["arn:aws:logs:${var.region}:${local.account_id}:log-group:/ecs/${local.name}*"]
  }

  statement {
    sid = "ProjectRoles"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:PassRole",
    ]
    resources = [local.project_role_arn]
  }

  statement {
    sid       = "ProjectRoleManagedPolicies"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = [local.project_role_arn]

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = [local.read_only_policy_arn, local.ecs_lb_policy_arn]
    }
  }

  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/aws-service-role/*"]
  }

  statement {
    sid       = "State"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.state_bucket}/demo/*"]
  }

  statement {
    sid       = "StateBucket"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.state_bucket}"]
  }
}

resource "aws_iam_role_policy" "gh_infra_apply" {
  name   = "infra-apply"
  role   = aws_iam_role.gh_infra_apply.id
  policy = data.aws_iam_policy_document.gh_infra_apply.json
}

# gh-app-deploy: push, sign and deploy the image from main

resource "aws_iam_role" "gh_app_deploy" {
  name               = "${local.name}-gh-app-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_trust["app-deploy"].json
}

data "aws_iam_policy_document" "gh_app_deploy" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
    resources = [local.ecr_repository_arn]
  }

  # These actions do not support resource-level permissions
  statement {
    sid       = "TaskDefinitions"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid       = "Service"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices", "ecs:ListServiceDeployments"]
    resources = [local.ecs_service_arn]
  }

  statement {
    sid       = "ServiceDeployments"
    actions   = ["ecs:DescribeServiceDeployments"]
    resources = ["arn:aws:ecs:${var.region}:${local.account_id}:service-deployment/${aws_ecs_cluster.main.name}/${local.name}/*"]
  }

  statement {
    sid       = "PassTaskRole"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.task_execution.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "gh_app_deploy" {
  name   = "app-deploy"
  role   = aws_iam_role.gh_app_deploy.id
  policy = data.aws_iam_policy_document.gh_app_deploy.json
}

# Roles used by ECS itself

data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${local.name}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

data "aws_iam_policy_document" "task_execution" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [local.ecr_repository_arn]
  }

  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }
}

resource "aws_iam_role_policy" "task_execution" {
  name   = "task-execution"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.task_execution.json
}

data "aws_iam_policy_document" "ecs_infrastructure_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_infrastructure" {
  name               = "${local.name}-ecs-infrastructure"
  assume_role_policy = data.aws_iam_policy_document.ecs_infrastructure_trust.json
}

resource "aws_iam_role_policy_attachment" "ecs_infrastructure" {
  role       = aws_iam_role.ecs_infrastructure.name
  policy_arn = local.ecs_lb_policy_arn
}
