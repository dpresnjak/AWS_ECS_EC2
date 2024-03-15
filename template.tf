# ECS cluster
# ASG with launch templates, ALB, target groups
# ECS with service, tasks (httpd, postgres kinda), EC2 capacity provider
# Using ECS optimized AMI
# API Gateway with ALB integration
# Cloudfront distribution
# https://docs.aws.amazon.com/AmazonECS/latest/developerguide/create-container-image.html

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
# Configure the AWS Provider
provider "aws" {
  region = "us-east-1"
}

# ECS IAM stuff
data "aws_iam_policy" "ECSPolicy" {
  arn = "arn:aws:iam::aws:policy/AmazonECS_FullAccess"
}
resource "aws_iam_instance_profile" "ecs_ec2_profile" {
  name = "${var.prefix}ECSEc2Profile"
  role = aws_iam_role.ecsInstanceRole.name
}
resource "aws_iam_role" "ecsInstanceRole" {
  name = "ecsInstanceRole"
  #managed_policy_arns = [ "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role" ]
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = "ECSAssume"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}
resource "aws_iam_role_policy_attachment" "ecsAttach" {
  role = aws_iam_role.ecsInstanceRole.name
  policy_arn = data.aws_iam_policy.ECSPolicy.arn
}

resource "aws_cloudfront_distribution" "cloudfront_alb" {
  default_root_object = "index.html"
  enabled = true
  default_cache_behavior {
    target_origin_id = aws_lb.ecs_alb.id
    allowed_methods = [ "HEAD","GET" ]
    cached_methods = [ "HEAD","GET" ]
    viewer_protocol_policy = "allow-all"
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }
  origin {
    domain_name = aws_lb.ecs_alb.dns_name
    custom_origin_config {
      http_port = 80
      https_port = 443
      origin_protocol_policy = "match-viewer"
      origin_ssl_protocols = [ "TLSv1", "TLSv1.1", "TLSv1.2", "SSLv3" ]
    }
    origin_id = aws_lb.ecs_alb.id
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version = "TLSv1"
  }
}

# ECS CLuster, placement group
resource "aws_ecs_cluster" "ecs_cluster" {
  name = "${var.prefix}Cluster"
}
resource "aws_placement_group" "placement_group" {
  name = "${var.prefix}PlacementGroup"
  strategy = "spread"
}


# Launch template and ASG
resource "aws_launch_template" "launch_template" {
  block_device_mappings {
    device_name = "/dev/sdf"
    ebs {
      volume_size = 20
    }
  }
  disable_api_stop = false
  disable_api_termination = false
  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_ec2_profile.name
  }
  #image_id = data.aws_ami.amazon_linux_ami.id
  image_id = "ami-045a946a7171d63ce"
  instance_initiated_shutdown_behavior = "terminate"
  instance_type = "t2.micro"
  metadata_options {
    http_endpoint = "enabled"
    http_tokens = "required"
    instance_metadata_tags = "enabled"
  }
  monitoring {
    enabled = true
  }
  network_interfaces {
    associate_public_ip_address = true
  }
  placement {
    availability_zone = "us-east-1a"
  }
  #vpc_security_group_ids = ["${var.vpc_sg_id}"]
  user_data = filebase64("./userdata.sh")
  key_name = "dpresnjak-key"
  tags = {
    "name" = "dpres"
  }
}
resource "aws_autoscaling_group" "ecs_asg" {
  name = "${var.prefix}ASG"
  max_size = 2
  min_size = 1
  health_check_grace_period = 300
  health_check_type = "ELB"
  desired_capacity = 2
  force_delete = true
  placement_group = aws_placement_group.placement_group.id
  launch_template {
    id = aws_launch_template.launch_template.id
    version = "$Latest"
  }
  availability_zones = ["us-east-1a", "us-east-1b"]
  default_cooldown = 300
  default_instance_warmup = 300

}
# Load Balancer config
resource "aws_lb" "ecs_alb" {
  name = "${var.prefix}EcsAlb"
  internal = false
  load_balancer_type = "application"
  subnets = [ "subnet-18d61747", "subnet-0260a564" ]
}
resource "aws_lb_listener" "ecs_alb_listener" {
  load_balancer_arn = aws_lb.ecs_alb.arn
  port = 80
  protocol = "HTTP"
  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.ecs_alb_tg.arn
  }
}
resource "aws_lb_target_group" "ecs_alb_tg" {
  name = "${var.prefix}EcsTargetGroup"
  port = 80
  protocol = "HTTP"
  #target_type = "alb"
  vpc_id = "${var.vpc_id}"
  health_check {
    path = "/"
    interval = 300
    unhealthy_threshold = 2
  }
}
resource "aws_autoscaling_attachment" "asg_attachment" {
  autoscaling_group_name = aws_autoscaling_group.ecs_asg.name
  lb_target_group_arn = aws_lb_target_group.ecs_alb_tg.arn
}
# ECS tasks and services
resource "aws_ecs_task_definition" "ecs_webserver_task" {
  family = "service"
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture = "X86_64"
  }
  container_definitions = jsonencode([
    {
      name = "httpd"
      image = "public.ecr.aws/docker/library/httpd:latest"
      cpu = 20
      memory = 50
      essential = true
      portMappings = [
        {
          containerPort = 80
          hostPort = 80
          protocol = "tcp"
        }
      ]
      log_configuration = {
        log_driver = "awslogs"
        options = {
          awslogs_group = "dpresnjak-cicd"
          awslogs_region = "us-east-1"
          awslogs_stream_prefix = "httpd"
        }
      }
    },
    # {
    #   name = "postgresql"
    #   image = "public.ecr.aws/docker/library/postgres:latest"
    #   cpu = 20
    #   memory = 50
    #   essential = true
    #   portMappings = [
    #     {
    #       containerPort = 5432
    #       hostPort = 5432
    #       protocol = "tcp"
    #     }
    #   ]
    #   log_configuration = {
    #     log_driver = "awslogs"
    #     options = {
    #       awslogs_group = "dpresnjak-cicd"
    #       awslogs_region = "us-east-1"
    #       awslogs_stream_prefix = "psql"
    #     }
    #   }
    # },
  ])
  
}
resource "aws_ecs_service" "ecs_ec2_services" {
  name = "backend"
  cluster = aws_ecs_cluster.ecs_cluster.id
  task_definition = aws_ecs_task_definition.ecs_webserver_task.arn
  desired_count = 2
}

# EC2 Capacity provider for ECS
resource "aws_ecs_cluster_capacity_providers" "ec2_provider" {
  cluster_name = aws_ecs_cluster.ecs_cluster.name
  capacity_providers = ["${aws_ecs_capacity_provider.ecs_ec2.name}", "FARGATE"]
  default_capacity_provider_strategy {
    base = 1
    weight = 50
    capacity_provider = "FARGATE"
  }
}
resource "aws_ecs_capacity_provider" "ecs_ec2" {
  name = "${var.prefix}CapacityProvEc2"
  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.ecs_asg.arn
    managed_termination_protection = "DISABLED"
    managed_scaling {
      instance_warmup_period = 300
      status = "ENABLED"
      target_capacity = 2
    }
  }
}

# Fargate Capacity provider for ECS

# API Gateway
resource "aws_api_gateway_account" "main" {
  cloudwatch_role_arn = aws_iam_role.rest_api_cw_role.arn
}
resource "aws_iam_role" "rest_api_cw_role" {
  name = "api-gateway-logs-role"
  assume_role_policy = jsonencode({
      "Version": "2012-10-17",
      "Statement": [
        {
          "Sid": "",
          "Effect": "Allow",
          "Principal": {
            "Service": "apigateway.amazonaws.com"
          },
          "Action": "sts:AssumeRole"
        }
      ]
    })
}
resource "aws_iam_role_policy_attachment" "main" {
  role       = aws_iam_role.rest_api_cw_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}
resource "aws_api_gateway_rest_api" "rest_api" {
  name = "${var.prefix}RestApi"
  endpoint_configuration {
    types = [ "REGIONAL" ]
  }
}
resource "aws_api_gateway_resource" "rest_api_resource" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  parent_id = aws_api_gateway_rest_api.rest_api.root_resource_id
  path_part = "{proxy+}"
}
resource "aws_api_gateway_method" "rest_api_method" {
  resource_id = aws_api_gateway_resource.rest_api_resource.id
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  http_method = "GET"
  authorization = "NONE"
}
resource "aws_api_gateway_method_settings" "api_cw_logging" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  stage_name = aws_api_gateway_stage.rest_api_stage.stage_name
  method_path = "*/*"
  settings {
    logging_level = "INFO"
    metrics_enabled = true
    data_trace_enabled = true
  }
}
resource "aws_api_gateway_integration" "rest_api_lb" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  resource_id = aws_api_gateway_resource.rest_api_resource.id
  http_method = aws_api_gateway_method.rest_api_method.http_method
  integration_http_method = "GET"
  type = "HTTP_PROXY"
  #uri = "${aws_lb_listener.ecs_alb_listener.dns_name}/{proxy+}"
  uri = "http://${aws_lb.ecs_alb.dns_name}:80/"
}
resource "aws_api_gateway_deployment" "rest_api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  triggers = {
    redepoyment = sha1(jsonencode(aws_api_gateway_rest_api.rest_api.body))
  }
  lifecycle {
    create_before_destroy = true
  }
  depends_on = [ aws_api_gateway_method.rest_api_method ]
}
resource "aws_api_gateway_stage" "rest_api_stage" {
  deployment_id = aws_api_gateway_deployment.rest_api_deployment.id
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  stage_name = "v1"
}

# Amazon Linux AMI - ECS optimized
data "aws_ami" "amazon_linux_ami" {
  most_recent = true
  owners = ["amazon"]
  filter {
    name = "name"
    values = ["al2023-ami-2023*"]
  }
  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name = "architecture"
    values = ["x86_64"]
  }
}

# Output values
output "api_gateway_uri" {
  value = aws_api_gateway_stage.rest_api_stage.invoke_url
}
output "lb_endpoint" {
  value = aws_lb.ecs_alb.dns_name
}