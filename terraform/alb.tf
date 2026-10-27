resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public HTTP access to the ALB"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Traffic to ECS tasks"
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
}

resource "aws_lb" "main" {
  name                       = local.name
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.public[*].id
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "app" {
  for_each = toset(["blue", "green"])

  name                 = "${local.name}-${each.key}"
  port                 = var.container_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "not found"
      status_code  = "404"
    }
  }
}

# ECS shifts the weights between blue and green during deployments
resource "aws_lb_listener_rule" "production" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type = "forward"

    forward {
      target_group {
        arn    = aws_lb_target_group.app["blue"].arn
        weight = 100
      }

      target_group {
        arn    = aws_lb_target_group.app["green"].arn
        weight = 0
      }
    }
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }

  lifecycle {
    ignore_changes = [action]
  }
}

resource "aws_lb_listener_rule" "test" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type = "forward"

    forward {
      target_group {
        arn    = aws_lb_target_group.app["blue"].arn
        weight = 100
      }

      target_group {
        arn    = aws_lb_target_group.app["green"].arn
        weight = 0
      }
    }
  }

  condition {
    http_header {
      http_header_name = "X-Deployment-Test"
      values           = ["true"]
    }
  }

  lifecycle {
    ignore_changes = [action]
  }
}
