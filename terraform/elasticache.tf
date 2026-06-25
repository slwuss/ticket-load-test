resource "aws_security_group" "redis" {
  name   = "ticketing-redis-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
}

resource "aws_elasticache_subnet_group" "ticketing" {
  name       = "ticketing-redis-subnet"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_elasticache_replication_group" "ticketing" {
  replication_group_id = "ticketing-redis"
  description          = "Seat lock + session cache"

  node_type          = "cache.r7g.medium"  # 1 vCPU, 6.4GB
  num_cache_clusters = 1                    # single node, no replicas
  port               = 6379

  subnet_group_name  = aws_elasticache_subnet_group.ticketing.name
  security_group_ids = [aws_security_group.redis.id]

  automatic_failover_enabled = false
  multi_az_enabled           = false
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  maintenance_window       = "sun:05:00-sun:06:00"
  snapshot_retention_limit = 1
}

output "redis_endpoint" {
  value     = aws_elasticache_replication_group.ticketing.primary_endpoint_address
  sensitive = true
}
