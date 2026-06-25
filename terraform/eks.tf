module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.11.1"

  cluster_name    = var.cluster_name
  cluster_version = "1.29"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Allow kubectl from within VPC only
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true

  # Cluster addons
  cluster_addons = {
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    vpc-cni                = { most_recent = true }
    aws-ebs-csi-driver     = { most_recent = true }
  }

  eks_managed_node_groups = {
    # On-demand nodes — always-on baseline (1 pods guaranteed)
    on_demand = {
      name           = "on-demand"
      instance_types = ["m5.xlarge"]   # 4 vCPU, 16GB — fits ~8 pods comfortably
      capacity_type  = "ON_DEMAND"
      min_size       = 1
      desired_size   = 1
      max_size       = 6
      disk_size      = 50

      labels = { role = "on-demand" }
    }

    # Spot nodes — absorb burst traffic at ~70% cost reduction
    spot = {
      name           = "spot"
      instance_types = ["m5.xlarge", "m5a.xlarge", "m5d.xlarge"]
      capacity_type  = "SPOT"
      min_size       = 0
      desired_size   = 0
      max_size       = 15
      disk_size      = 50

      labels = { role = "spot" }
      taints = [{
        key    = "spot"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }

    # Monitoring node — dedicated to Prometheus, Grafana, alerting stack
    # Taint prevents any non-monitoring pod from being scheduled here
    monitoring = {
      name           = "monitoring"
      instance_types = ["m5.large"]   # 2 vCPU, 8GB — sufficient for Prometheus + Grafana
      capacity_type  = "ON_DEMAND"
      min_size       = 1
      desired_size   = 1
      max_size       = 2
      disk_size      = 50

      labels = { role = "monitoring" }
      taints = [{
        key    = "dedicated"
        value  = "monitoring"
        effect = "NO_SCHEDULE"
      }]
    }
  }

  # Cluster Autoscaler IAM
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }
}

# ── Cluster Autoscaler ────────────────────────────────────────────────────────
resource "aws_iam_policy" "cluster_autoscaler" {
  name = "${var.cluster_name}-cluster-autoscaler"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup",
        "ec2:DescribeImages",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:GetInstanceTypesFromInstanceRequirements",
        "eks:DescribeNodegroup"
      ]
      Resource = "*"
    }]
  })
}
