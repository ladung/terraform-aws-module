# ALB
variable "elb_sg_ingress_ports" {
  type    = list(number)
  default = [80, 443, 8080]
}

resource "aws_security_group" "application_elb_sg" {
  vpc_id = var.vpc_id
  name   = "application_elb_sg"
}

resource "aws_security_group_rule" "application_elb_sg_ingress" {
  count             = length(var.elb_sg_ingress_ports)
  type              = "ingress"
  from_port         = var.elb_sg_ingress_ports[count.index]
  to_port           = var.elb_sg_ingress_ports[count.index]
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.application_elb_sg.id
} 

resource "aws_lb" "app_lb" {
  name               = "application_load_balancer"
  load_balancer_type = "application"
  subnets            = var.public_subnets[*].id
  idle_timeout       = 60
  security_groups    = [aws_security_group.application_elb_sg.id]
}

# Target groups & listener
variable "lb_target_group_name" {
  type    = string
  default = "tg"
}

locals {
  target_groups = [
    "green",
    "blue",
  ]
}

resource "aws_lb_target_group" "tg" {
  count = length(local.target_groups)

  name        = "${var.lb_target_group_443_name}-${element(local.target_groups, count.index)}"
  port        = 443
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = var.vpc_id
  health_check {
    matcher = "200,301,302,404"
    path    = "/"
  }

}

resource "aws_alb_listener" "l_80" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_alb_listener" "l_8080" {
  load_balancer_arn = aws_lb.app_lb.id
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg[1].arn
  }
}

resource "aws_alb_listener" "l_443" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = "443"
  protocol          = "HTTPS"
  certificate_arn   = XXXX
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg[0].arn
  }
  depends_on = [aws_lb_target_group.tg]

  lifecycle {
    ignore_changes = [default_action]
  }
}

#ECS
resource "aws_ecr_repository" "app_ecr_repo" {
  name         = "app-ecr-repository"
  force_delete = true
}

resource "aws_ecs_cluster" "app_cluster" {
  name = "application_cluster"
}

resource "aws_ecs_service" "frontend" {
  name                               = "frontend"
  cluster                            = aws_ecs_cluster.app_cluster.id
  task_definition                    = aws_ecs_task_definition.frontend_task.arn
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 300
  launch_type                        = "EC2"
  scheduling_strategy                = "REPLICA"
  desired_count                      = 1


  force_new_deployment = true
  load_balancer {
    target_group_arn = aws_lb_target_group.tg[0].arn
    container_name   = "app" 
    container_port   = "80" # Application Port
  }
  deployment_controller {
    type = "CODE_DEPLOY"
  }


  # workaround for https://github.com/hashicorp/terraform/issues/12634
  depends_on = [aws_lb.app_cluster]
  # we ignore task_definition changes as the revision changes on deploy
  # of a new version of the application
  # desired_count is ignored as it can change due to autoscaling policy
  lifecycle {
    ignore_changes = [task_definition, desired_count, load_balancer]
  }
}


resource "aws_ecs_task_definition" "frontend_task" {
  family = "frontend-task" 
  container_definitions = jsonencode([{


    name      = "app",
    image     = "${var.aws_account_id}.dkr.ecr.${var.aws_account_region}.amazonaws.com/app-ecr-repository:<revision_number>",
    essential = true,
    portMappings = [
      {
        "containerPort" : 80 # Application Port
      }
    ],




    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.main.name
        awslogs-stream-prefix = "ecs"
        awslogs-region        = var.region
      }
    }
  }])
  requires_compatibilities = ["EC2"] # Stating that we are using ECS Fargate # Using awsvpc as our network mode as this is required for Fargate
  memory                   = 1800    # Specifying the memory our container requires
  cpu                      = 512     # Specifying the CPU our container requires
  execution_role_arn       = aws_iam_role.app_task_role.arn

}

# IAM role for ECS
resource "aws_iam_role" "app_task_role" {
  name = "app-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ECS_task_execution" {
  role       = aws_iam_role.app_task_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}


# Code Deploy
resource "aws_codedeploy_app" "frontend" {
  compute_platform = "ECS"
  name             = "frontend-deploy"
}
resource "aws_codedeploy_deployment_group" "frontend" {
  app_name               = aws_codedeploy_app.frontend.name
  deployment_group_name  = "frontend-deploy-group"
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"
  service_role_arn       = aws_iam_role.codedeploy.arn

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }

    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 1
    }
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.app_cluster.name
    service_name = aws_ecs_service.frontend.name
  }

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }
  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_alb_listener.l_443.arn]
      }

      target_group {
        name = aws_lb_target_group.tg[0].name
      }

      target_group {
        name = aws_lb_target_group.tg[1].name
      }

      
    }
  }

}

data "aws_iam_policy_document" "assume_by_codedeploy" {
  statement {
    sid     = ""
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codedeploy" {
  name               = "codedeploy"
  assume_role_policy = data.aws_iam_policy_document.assume_by_codedeploy.json
}


data "aws_iam_policy_document" "codedeploy" {
  statement {
    sid    = "AllowLoadBalancingAndECSModifications"
    effect = "Allow"

    actions = [
      "ecs:CreateTaskSet",
      "ecs:DeleteTaskSet",
      "ecs:DescribeServices",
      "ecs:UpdateServicePrimaryTaskSet",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:ModifyRule",
      "s3:GetObject"
    ]

    resources = ["*"]
  }
  statement {
    sid    = "AllowPassRole"
    effect = "Allow"

    actions = ["iam:PassRole"]

    resources = [
      aws_iam_role.app_task_role.arn
    ]
  }

  statement {
    sid    = "DeployService"
    effect = "Allow"

    actions = ["ecs:DescribeServices",
      "codedeploy:GetDeploymentGroup",
      "codedeploy:CreateDeployment",
      "codedeploy:GetDeployment",
      "codedeploy:GetDeploymentConfig",
    "codedeploy:RegisterApplicationRevision"]

    resources = [
      aws_ecs_service.frontend.id,
      aws_codedeploy_deployment_group.frontend.arn,
      "arn:aws:codedeploy:${var.region}:${var.aws_account_id}:deploymentconfig:*}",
      aws_codedeploy_app.frontend.arn
    ]
  }


}
resource "aws_iam_role_policy" "codedeploy" {
  role   = aws_iam_role.codedeploy.name
  policy = data.aws_iam_policy_document.codedeploy.json
}