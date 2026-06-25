# Generate SSH key pair and upload to AWS
resource "tls_private_key" "load_test" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "load_test" {
  key_name   = "ec2key"
  public_key = tls_private_key.load_test.public_key_openssh
}

resource "local_sensitive_file" "load_test_pem" {
  content         = tls_private_key.load_test.private_key_pem
  filename        = "${path.module}/ec2key.pem"
  file_permission = "0600"
}

output "ssh_private_key_path" {
  description = "Path to the generated SSH private key"
  value       = local_sensitive_file.load_test_pem.filename
}

# Latest Ubuntu 24.04 LTS AMI
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_iam_role" "load_test" {
  name = "ticketing-load-test-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "load_test_eks" {
  role       = aws_iam_role.load_test.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "load_test_ecr" {
  role       = aws_iam_role.load_test.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "load_test" {
  name = "ticketing-load-test-profile"
  role = aws_iam_role.load_test.name
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

# Allow the load test instance to reach the EKS API server (port 443)
resource "aws_security_group_rule" "eks_api_from_load_test" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = module.eks.cluster_security_group_id
  source_security_group_id = aws_security_group.load_test.id
  description              = "Load test instance to EKS API server"
}

resource "aws_instance" "load_test" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.large"   # 2 vCPU, 8GB — enough to saturate the cluster
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.load_test.id]
  key_name                    = aws_key_pair.load_test.key_name
  iam_instance_profile        = aws_iam_instance_profile.load_test.name
  associate_public_ip_address = true

  user_data = <<-EOF
    #!/bin/bash
    set -e

    apt-get update -y
    apt-get install -y curl unzip gnupg

    # Install k6
    gpg -k
    curl -fsSL https://dl.k6.io/key.gpg | gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | tee /etc/apt/sources.list.d/k6.list
    apt-get update -y
    apt-get install -y k6

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
  description = "SSH: ubuntu@<ip>  then: aws eks update-kubeconfig --region ap-southeast-2 --name ticketing-eks"
  value       = aws_instance.load_test.public_ip
}
