# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.environment}-bmdb-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = {
    Name        = "${var.environment}-bmdb-cluster"
    Environment = var.environment
  }
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "main" {
  name              = "/ecs/${var.environment}-bmdb"
  retention_in_days = 7

  tags = {
    Name        = "${var.environment}-bmdb-logs"
    Environment = var.environment
  }
}

# ECS Task Execution Role
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.environment}-bmdb-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "${var.environment}-bmdb-execution-role"
    Environment = var.environment
  }
}

# Attach the AWS managed ECS Task Execution Role policy
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow Task Execution Role to read from Secrets Manager and SSM Parameter Store
resource "aws_iam_policy" "secrets_access" {
  name        = "${var.environment}-bmdb-task-secrets-policy"
  description = "Allow ECS tasks to access secrets and parameters"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Effect   = "Allow"
        Resource = var.secrets_arn != "" ? [var.secrets_arn] : ["*"]
      },
      {
        Action = [
          "ssm:GetParameters",
          "ssm:GetParameter"
        ]
        Effect   = "Allow"
        Resource = "arn:aws:ssm:*:*:parameter/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_secrets_access" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = aws_iam_policy.secrets_access.arn
}

# Security Group for ECS Tasks
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.environment}-bmdb-ecs-tasks-sg"
  description = "Allow inbound traffic to ECS tasks"
  vpc_id      = var.vpc_id

  ingress {
    protocol        = "tcp"
    from_port       = var.app_port
    to_port         = var.app_port
    cidr_blocks     = ["0.0.0.0/0"]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment}-bmdb-ecs-tasks-sg"
    Environment = var.environment
  }
}

# ECS# Task definition
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.environment}-bmdb"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.fargate_cpu
  memory                   = var.fargate_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name          = "bmdb"
      image         = var.app_image
      essential     = true
      portMappings  = [
        {
          containerPort = var.app_port
          hostPort      = var.app_port
          protocol      = "tcp"
        }
      ]
      # Use secrets if secrets_arn is provided
      secrets = var.secrets_arn != "" ? [
        {
          name      = "DATABASE_HOST"
          valueFrom = "${var.secrets_arn}:DATABASE_HOST::"
        },
        {
          name      = "DATABASE_USER"
          valueFrom = "${var.secrets_arn}:DATABASE_USER::"
        },
        {
          name      = "DATABASE_PASSWORD"
          valueFrom = "${var.secrets_arn}:DATABASE_PASSWORD::"
        },
        {
          name      = "DATABASE_NAME"
          valueFrom = "${var.secrets_arn}:DATABASE_NAME::"
        }
      ] : []
      
      # Use environment variables if no secrets_arn is provided
      environment = var.secrets_arn == "" ? [
        {
          name  = "DATABASE_HOST"
          value = var.db_host != "" ? var.db_host : "localhost"
        },
        {
          name  = "DATABASE_USER"
          value = var.db_username
        },
        {
          name  = "DATABASE_PASSWORD"
          value = var.db_password
        },
        {
          name  = "DATABASE_NAME"
          value = var.db_name
        }
      ] : []
      
      user = "root"
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.main.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  tags = {
    Name        = "${var.environment}-bmdb-task"
    Environment = var.environment
  }
}

# ALB Security Group
resource "aws_security_group" "alb" {
  name        = "${var.environment}-bmdb-alb-sg"
  description = "Controls access to the ALB"
  vpc_id      = var.vpc_id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment}-bmdb-alb-sg"
    Environment = var.environment
  }
}

# Application Load Balancer
resource "aws_lb" "main" {
  name               = "${var.environment}-bmdb-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = false

  tags = {
    Name        = "${var.environment}-bmdb-alb"
    Environment = var.environment
  }
}

# ALB Target Group
resource "aws_lb_target_group" "app" {
  name        = "${var.environment}-bmdb-tg"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"
  deregistration_delay = 30  # Reduced from default 300 seconds to save costs

  health_check {
    healthy_threshold   = 2  # Reduced from 3
    unhealthy_threshold = 2  # Reduced from 3
    timeout             = 3  # Reduced from 5
    interval            = 60  # Increased from 30 to reduce CloudWatch metrics
    path                = "/"
    protocol            = "HTTP"
  }

  tags = {
    Name        = "${var.environment}-bmdb-tg"
    Environment = var.environment
  }
}

# ALB Listener
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ECS Service
resource "aws_ecs_service" "main" {
  name            = "${var.environment}-bmdb-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.app_count
  # Remove launch_type as we're using capacity_provider_strategy
  # Enable deployment circuit breaker for faster rollbacks without capacity loss
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  
  # Optimize deployment strategy 
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100
  
  # Enable Fargate Spot for non-prod environments to save costs
  capacity_provider_strategy {
    capacity_provider = var.environment == "prod" ? "FARGATE" : "FARGATE_SPOT"
    weight            = 1
    base              = 0
  }

  network_configuration {
    security_groups  = [aws_security_group.ecs_tasks.id]
    subnets          = var.private_subnet_ids
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "bmdb"
    container_port   = var.app_port
  }

  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy_attachment.ecs_task_execution_role_policy,
    aws_iam_role_policy_attachment.ecs_secrets_access
  ]

  tags = {
    Name        = "${var.environment}-bmdb-service"
    Environment = var.environment
  }
}

# Auto Scaling for ECS
resource "aws_appautoscaling_target" "ecs_target" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.main.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.environment == "prod" ? 1 : 0  # Allow scale to zero in non-prod
  max_capacity       = var.environment == "prod" ? 5 : 2
}

# Auto Scaling Policy - CPU
resource "aws_appautoscaling_policy" "ecs_cpu" {
  name               = "${var.environment}-bmdb-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# Auto Scaling Policy - Memory
resource "aws_appautoscaling_policy" "ecs_memory" {
  name               = "${var.environment}-bmdb-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# Schedule to scale up during business hours - Only for non-production environments
resource "aws_appautoscaling_scheduled_action" "scale_up" {
  count              = var.environment != "prod" && var.enable_scheduled_scaling ? 1 : 0
  name               = "${var.environment}-bmdb-scale-up"
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  schedule           = "cron(0 ${split(":", var.business_hours_start)[0]} ? * ${join(",", var.business_days)} *)"
  
  scalable_target_action {
    min_capacity = 1
    max_capacity = 2
  }
}

# Schedule to scale down after business hours - Only for non-production environments
resource "aws_appautoscaling_scheduled_action" "scale_down" {
  count              = var.environment != "prod" && var.enable_scheduled_scaling ? 1 : 0
  name               = "${var.environment}-bmdb-scale-down"
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  schedule           = "cron(0 ${split(":", var.business_hours_end)[0]} ? * ${join(",", var.business_days)} *)"
  
  scalable_target_action {
    min_capacity = 0
    max_capacity = 1
  }
}
