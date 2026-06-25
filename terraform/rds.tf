resource "aws_db_subnet_group" "ticketing" {
  name       = "ticketing-db-subnet"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "rds" {
  name   = "ticketing-rds-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
}

resource "aws_db_instance" "ticketing" {
  identifier              = "ticketing-postgres"
  engine                  = "postgres"
  engine_version          = "16.9"
  instance_class          = "db.r6g.xlarge"  # 4 vCPU, 32GB — handles ~500 conn
  allocated_storage       = 100
  max_allocated_storage   = 500              # auto-scale storage

  db_name  = "ticketing"
  username = "ticketing"
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.ticketing.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az               = false  # disabled for load testing — standby adds cost, not throughput
  backup_retention_period = 7
  backup_window          = "03:00-04:00"
  maintenance_window     = "Mon:04:00-Mon:05:00"

  deletion_protection    = true
  skip_final_snapshot    = false
  final_snapshot_identifier = "ticketing-final-snapshot"

  performance_insights_enabled = true

  tags = { Name = "ticketing-postgres" }
}

output "rds_endpoint" {
  value     = aws_db_instance.ticketing.endpoint
  sensitive = true
}
