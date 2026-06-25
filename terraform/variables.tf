variable "region" {
  default = "ap-southeast-2"
}

variable "cluster_name" {
  default = "ticketing-eks"
}

variable "db_password" {
  description = "RDS master password"
  sensitive   = true
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
}
