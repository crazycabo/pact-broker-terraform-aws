provider "aws" {
  region  = "us-east-1"
  profile = "profile_name"
}

resource "random_string" "snapshot_id" {
  length = 16
  special = false
}

########################################
# RDS - Postgres
########################################

resource "aws_db_instance" "pact_broker" {
  allocated_storage          = 20
  max_allocated_storage      = 100
  storage_type               = "gp2"
  engine                     = "postgres"
  engine_version             = "11.9"
  instance_class             = "db.t2.medium"
  port                       = 5432
  name                       = "brokerpact"
  username                   = "pbuser"
  password                   = "changeme"
  backup_retention_period    = 7
  storage_encrypted          = false
  publicly_accessible        = true
  db_subnet_group_name       = aws_db_subnet_group.pact_broker.name
  vpc_security_group_ids     = [aws_security_group.pact_broker_database.id]
  final_snapshot_identifier  = format("%s%s", "pact-broker-", random_string.snapshot_id.result)

  tags = {
    Name = "pact-broker"
  }
}

resource "aws_db_subnet_group" "pact_broker" {
  name       = "pact-broker-subnet-group"

  subnet_ids = [
    aws_subnet.pact_broker_a.id,
    aws_subnet.pact_broker_b.id
  ]
}

resource "aws_security_group" "pact_broker_database" {
  # name   = "pact-broker-db"
  vpc_id = aws_vpc.pact_broker.id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = []
  }

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.pact_broker_ecs.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "pact-broker-database"
  }
}

########################################
# ECS
########################################

resource "aws_ecs_cluster" "pact_broker" {
  name = "pact_broker"
}

resource "aws_ecs_task_definition" "pact_broker" {
  family                   = "pact-broker-task"

  container_definitions    = <<DEFINITION
  [
    {
      "name": "pact-broker-task",
      "image": "pactfoundation/pact-broker:latest",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 9292,
          "hostPort": 9292
        }
      ],
      "cpu": 256,
      "memoryReservation": 512,
      "environment": [
        {
          "name": "PACT_BROKER_DATABASE_USERNAME",
          "value": "${aws_db_instance.pact_broker.username}"
        },
        {
          "name": "PACT_BROKER_DATABASE_PASSWORD",
          "value": "changeme"
        },
        {
          "name": "PACT_BROKER_DATABASE_HOST",
          "value": "${aws_db_instance.pact_broker.address}"
        },
        {
          "name": "PACT_BROKER_DATABASE_NAME",
          "value": "${aws_db_instance.pact_broker.name}"
        },
        {
          "name": "PACT_BROKER_PUMA_PERSISTENT_TIMEOUT",
          "value": "120"
        },
        {
          "name": "PACT_BROKER_BASIC_AUTH_USERNAME",
          "value": "pbadmin"
        },
        {
          "name": "PACT_BROKER_BASIC_AUTH_PASSWORD",
          "value": "changeme"
        },
        {
          "name": "PACT_BROKER_ALLOW_PUBLIC_READ",
          "value": "true"
        },
        {
          "name": "PACT_BROKER_LOG_LEVEL",
          "value": "DEBUG"
        }
      ],
      "logConfiguration": {
          "logDriver": "awslogs",
          "options": {
            "awslogs-group": "${aws_cloudwatch_log_group.pact_broker.name}",
            "awslogs-region": "us-east-1",
            "awslogs-stream-prefix": "ecs"
          }
        }
    }
  ]
  DEFINITION

  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  memory                   = 512
  cpu                      = 256
  execution_role_arn       = aws_iam_role.ecsTaskExecutionRole.arn

  depends_on = [aws_db_instance.pact_broker]  # Database must be present before initializing the broker.
}

resource "aws_ecs_service" "pact_broker" {
  name                               = "pact-broker-service"
  cluster                            = aws_ecs_cluster.pact_broker.id
  task_definition                    = aws_ecs_task_definition.pact_broker.arn
  launch_type                        = "FARGATE"
  desired_count                      = 2
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 60

  lifecycle {
    ignore_changes = [desired_count]
  }

  network_configuration {
    subnets          = [
      aws_subnet.pact_broker_a.id,
      aws_subnet.pact_broker_b.id
    ]
    assign_public_ip = true
    security_groups = [aws_security_group.pact_broker_ecs.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.pact_broker.arn
    container_name   = aws_ecs_task_definition.pact_broker.family
    container_port   = 9292
  }

  depends_on = [aws_alb.pact_broker]
}

resource "aws_appautoscaling_target" "pact_broker" {
  max_capacity       = 8
  min_capacity       = 2
  resource_id        = "service/${aws_ecs_cluster.pact_broker.name}/${aws_ecs_service.pact_broker.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "pact_broker_cpu" {
  name               = "pact-broker-cpu-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.pact_broker.resource_id
  scalable_dimension = aws_appautoscaling_target.pact_broker.scalable_dimension
  service_namespace  = aws_appautoscaling_target.pact_broker.service_namespace

  target_tracking_scaling_policy_configuration {
   predefined_metric_specification {
     predefined_metric_type = "ECSServiceAverageCPUUtilization"
   }

   target_value       = 60
   scale_out_cooldown = 60
   scale_in_cooldown  = 300
  }
}

resource "aws_security_group" "pact_broker_ecs" {
  name   = "pact-broker-ecs"
  vpc_id = aws_vpc.pact_broker.id

  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.pact_broker_alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "pact-broker-ecs"
  }
}

resource "aws_iam_role" "ecsTaskExecutionRole" {
  name               = "pact-broker-ecs-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRole_policy" {
  role       = aws_iam_role.ecsTaskExecutionRole.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

########################################
# VPC
########################################

resource "aws_vpc" "pact_broker" {
  cidr_block = "10.1.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "pact-broker"
  }
}

resource "aws_internet_gateway" "pact_broker" {
  vpc_id = aws_vpc.pact_broker.id
}

# Subnet A
resource "aws_subnet" "pact_broker_a" {
  vpc_id = aws_vpc.pact_broker.id
  cidr_block = "10.1.0.0/20"
  map_public_ip_on_launch = "true"
  availability_zone = "us-east-1a"
}

resource "aws_route_table" "pact_broker_a" {
  vpc_id = aws_vpc.pact_broker.id
  route {
      cidr_block = "0.0.0.0/0"
      gateway_id = aws_internet_gateway.pact_broker.id
  }
}

resource "aws_route_table_association" "pact_broker_a" {
  subnet_id      = aws_subnet.pact_broker_a.id
  route_table_id = aws_route_table.pact_broker_a.id
}

# Subnet B
resource "aws_subnet" "pact_broker_b" {
  vpc_id = aws_vpc.pact_broker.id
  cidr_block = "10.1.16.0/20"
  map_public_ip_on_launch = "true"
  availability_zone = "us-east-1b"
}

resource "aws_route_table" "pact_broker_b" {
  vpc_id = aws_vpc.pact_broker.id
  route {
      cidr_block = "0.0.0.0/0"
      gateway_id = aws_internet_gateway.pact_broker.id
  }
}

resource "aws_route_table_association" "pact_broker_b" {
  subnet_id      = aws_subnet.pact_broker_b.id
  route_table_id = aws_route_table.pact_broker_b.id
}

########################################
# ALB
########################################

resource "aws_alb" "pact_broker" {
  name               = "pact-broker-load-balancer"
  load_balancer_type = "application"
  subnets = [
    aws_subnet.pact_broker_a.id,
    aws_subnet.pact_broker_b.id
  ]
  security_groups = [aws_security_group.pact_broker_alb.id]
}

resource "aws_security_group" "pact_broker_alb" {
  name = "pact-broker-alb"
  vpc_id = aws_vpc.pact_broker.id

  ingress {
    from_port   = 80
    to_port     = 9292
    protocol    = "tcp"
    cidr_blocks = []
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "pact-broker-alb"
  }
}

resource "aws_lb_target_group" "pact_broker" {
  name        = "pact-broker-target-group"
  port        = 9292
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.pact_broker.id
  health_check {
    matcher = "200,301,302"
    path = "/diagnostic/status/heartbeat"
  }
}

resource "aws_lb_listener" "pact_broker" {
  load_balancer_arn = aws_alb.pact_broker.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.pact_broker.arn
  }
}

########################################
# CloudWatch
########################################

resource "aws_cloudwatch_log_group" "pact_broker" {
  name = "/aws/ecs/pact-broker"
}
