variable "load_test_key_name" {
  description = "EC2 key pair name for SSH access to the load test instance"
  type        = string
}

# Latest Amazon Linux 2023 AMI
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "load_test" {
  name   = "ticketing-load-test-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Allow the load test instance to reach EKS nodes on all ports
resource "aws_security_group_rule" "eks_from_load_test" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = aws_security_group.load_test.id
  description              = "Load test instance to EKS nodes"
}

resource "aws_instance" "load_test" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.large"   # 2 vCPU, 8GB — enough to saturate the cluster
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.load_test.id]
  key_name                    = var.load_test_key_name
  associate_public_ip_address = true

  user_data = <<-EOF
    #!/bin/bash
    set -e

    # Install k6
    dnf install -y https://dl.k6.io/rpm/repo.rpm
    dnf install -y k6

    # Install kubectl
    curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

    # Install AWS CLI v2
    curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
    unzip -q awscliv2.zip
    ./aws/install
    rm -rf awscliv2.zip aws/

    # Install hey (HTTP load generator)
    curl -sL https://hey-release.s3.us-east-2.amazonaws.com/hey_linux_amd64 -o /usr/local/bin/hey
    chmod +x /usr/local/bin/hey
  EOF

  tags = {
    Name = "ticketing-load-test"
  }
}

output "load_test_public_ip" {
  description = "SSH: ec2-user@<ip>  then: aws eks update-kubeconfig --region ap-southeast-2 --name ticketing-eks"
  value       = aws_instance.load_test.public_ip
}
