terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = "us-east-2"
  profile = "aws-management"
}

locals {
  project = "storefront"
  env     = "dev"

  common_tags = {
    Project     = "ecommerce-storefront"
    Environment = "dev"
    ManagedBy   = "Terraform"
  }
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "storefront-dev-vpc"
  })
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "storefront-dev-igw"
  })
}

# Public subnet in AZ A
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.1.0/24"
  availability_zone       = "us-east-2a"
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "storefront-dev-public-a"
  })
}

# Public subnet in AZ B
resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.2.0/24"
  availability_zone       = "us-east-2b"
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "storefront-dev-public-b"
  })
}

# Public route table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "storefront-dev-public-rt"
  })
}

# Associate subnet A with public route table
resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

# Associate subnet B with public route table
resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# ALB Security Group: HTTP and HTTPS
resource "aws_security_group" "alb" {
  name        = "storefront-dev-alb-sg"
  description = "Allow public HTTP traffic to ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from the internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from the internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "storefront-dev-alb-sg"
  })
}

# EC2 Security Group
resource "aws_security_group" "ec2" {
  name        = "storefront-dev-ec2-sg"
  description = "Allow application traffic only from ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Application traffic from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "storefront-dev-ec2-sg"
  })
}

# EC2 IAM Role
resource "aws_iam_role" "ec2" {
  name = "storefront-dev-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

# Allow EC2 to pull images from ECR
resource "aws_iam_role_policy_attachment" "ecr_readonly" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Allow SSM management without SSH
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance Profile for EC2
resource "aws_iam_instance_profile" "ec2" {
  name = "storefront-dev-ec2-profile"
  role = aws_iam_role.ec2.name

  tags = local.common_tags
}

# EC2 Launch Template
resource "aws_launch_template" "web" {
  name_prefix   = "storefront-dev-"
  image_id      = "ami-03e224e4dbc21f89e"
  instance_type = "t3.micro"

  vpc_security_group_ids = [
    aws_security_group.ec2.id
  ]

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euxo pipefail

    dnf update -y
    dnf install -y docker
    systemctl enable --now docker

    aws ecr get-login-password --region us-east-2 \
      | docker login --username AWS --password-stdin \
        311937350493.dkr.ecr.us-east-2.amazonaws.com

    docker pull 311937350493.dkr.ecr.us-east-2.amazonaws.com/storefront-web:latest

    docker run -d \
      --name storefront-web \
      --restart unless-stopped \
      -p 80:80 \
      311937350493.dkr.ecr.us-east-2.amazonaws.com/storefront-web:latest
  EOF
  )

  tag_specifications {
    resource_type = "instance"

    tags = merge(local.common_tags, {
      Name = "storefront-dev-web"
    })
  }

  tags = merge(local.common_tags, {
    Name = "storefront-dev-launch-template"
  })
}

# Application Target Group
resource "aws_lb_target_group" "web" {
  name        = "storefront-dev-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(local.common_tags, {
    Name = "storefront-dev-tg"
  })
}

# Auto Scaling Group
resource "aws_autoscaling_group" "web" {
  name             = "storefront-dev-asg"
  min_size         = 1
  desired_capacity = 1
  max_size         = 2

  vpc_zone_identifier = [
    aws_subnet.public_a.id,
    aws_subnet.public_b.id
  ]

  target_group_arns = [
    aws_lb_target_group.web.arn
  ]

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  health_check_type         = "ELB"
  health_check_grace_period = 300

  tag {
    key                 = "Name"
    value               = "storefront-dev-web"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = local.common_tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

# Application Load Balancer
resource "aws_lb" "web" {
  name               = "storefront-dev-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]

  subnets = [
    aws_subnet.public_a.id,
    aws_subnet.public_b.id
  ]

  tags = merge(local.common_tags, {
    Name = "storefront-dev-alb"
  })
}

# HTTP Listener: redirect all HTTP requests to HTTPS
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
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

# HTTPS Listener: use the issued ACM certificate
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.web.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  certificate_arn = "arn:aws:acm:us-east-2:311937350493:certificate/d2b2bee2-1f1f-4c56-8645-6aaa461a7f4b"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# Useful deployment outputs
output "vpc_id" {
  description = "ID of the storefront VPC"
  value       = aws_vpc.main.id
}

output "alb_dns_name" {
  description = "Public DNS name of the storefront ALB"
  value       = aws_lb.web.dns_name
}

output "website_url" {
  description = "HTTPS URL of the storefront ALB"
  value       = "https://facetlab.alyrajewel.com"
}

output "target_group_arn" {
  description = "ARN of the storefront target group"
  value       = aws_lb_target_group.web.arn
}

output "autoscaling_group_name" {
  description = "Name of the storefront Auto Scaling Group"
  value       = aws_autoscaling_group.web.name
}



