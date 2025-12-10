terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

#######################
# 1. Networking: Default VPC + Security Group
#######################

# Use the default VPC (to keep things simple for the lab)
data "aws_vpc" "default" {
  default = true
}

# All subnets in the default VPC (we'll pick the first one)
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Security group allowing only HTTP/HTTPS from the internet
resource "aws_security_group" "web_sg" {
  name        = "${var.project_name}-sg"
  description = "Allow HTTP/HTTPS only"
  vpc_id      = data.aws_vpc.default.id

  # HTTP (optional if you strictly want HTTPS at the edge)
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTP from anywhere"
  }

  # HTTPS
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTPS from anywhere"
  }

  # Egress: allow all outbound (instance can reach internet for updates)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-sg"
    Project = var.project_name
  }
}

#######################
# 2. SSM Parameter (Secret)
#######################

resource "aws_ssm_parameter" "app_secret" {
  name        = "/${var.project_name}/APP_SECRET"
  description = "Example app secret for the web app"
  type        = "SecureString"
  value       = var.app_secret_value

  tags = {
    Project = var.project_name
  }
}

#######################
# 3. IAM Role & Instance Profile (no hard-coded creds)
#######################

# EC2 assume-role trust policy
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_role" {
  name               = "${var.project_name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Project = var.project_name
  }
}

# Policy: allow reading our specific SSM parameter
data "aws_iam_policy_document" "ec2_ssm_policy" {
  statement {
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters"
    ]

    resources = [
      aws_ssm_parameter.app_secret.arn
    ]
  }
}

resource "aws_iam_policy" "ec2_ssm_policy" {
  name   = "${var.project_name}-ec2-ssm-policy"
  policy = data.aws_iam_policy_document.ec2_ssm_policy.json

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "ec2_ssm_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.ec2_ssm_policy.arn
}

# Instance profile to attach the role to EC2
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "${var.project_name}-ec2-instance-profile"
  role = aws_iam_role.ec2_role.name
}

#######################
# 4. EC2 Instance + User Data
#######################

# Get latest Amazon Linux 2 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_instance" "app" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"

  # Use first subnet in the default VPC (simple for lab)
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  iam_instance_profile = aws_iam_instance_profile.ec2_instance_profile.name

  # User data: install Flask, fetch secret from SSM via IAM role, start app
  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y python3 python3-pip awscli

              # Fetch secret from SSM (using instance role)
              APP_SECRET=$(aws ssm get-parameter \
                --name "/${var.project_name}/APP_SECRET" \
                --with-decryption \
                --query "Parameter.Value" \
                --output text \
                --region ${var.region})

              echo "export APP_SECRET=$${APP_SECRET}" >> /etc/profile.d/app_env.sh
              source /etc/profile.d/app_env.sh

              pip3 install flask

              mkdir -p /opt/app
              cat > /opt/app/app.py << 'PYEOF'
              from flask import Flask
              import os

              app = Flask(__name__)

              @app.route("/")
              def index():
                  secret = os.environ.get("APP_SECRET", "not-set")
                  configured = bool(secret and secret != "not-set")
                  return f"Hello, secure world! Secret configured: {configured}"

              if __name__ == "__main__":
                  app.run(host="0.0.0.0", port=80)
              PYEOF

              # Start app on boot
              echo "cd /opt/app && source /etc/profile.d/app_env.sh && nohup python3 app.py &" >> /etc/rc.local
              chmod +x /etc/rc.d/rc.local
              /etc/rc.d/rc.local
              EOF

  tags = {
    Name    = "${var.project_name}-instance"
    Project = var.project_name
  }
}
