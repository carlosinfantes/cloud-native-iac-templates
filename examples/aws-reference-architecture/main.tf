terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# VPC Module
module "vpc" {
  source = "../../modules/vpc"

  name_prefix = local.name_prefix
  vpc_cidr    = var.vpc_cidr
  az_count    = var.availability_zone_count

  tags = local.common_tags
}

# Application Load Balancer Module
module "alb" {
  source = "../../modules/alb"

  name_prefix        = local.name_prefix
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids

  target_port         = 80
  health_check_path   = "/"
  certificate_arn     = var.ssl_certificate_arn
  access_logs_bucket  = var.alb_access_logs_bucket

  tags = local.common_tags
}

# Auto Scaling Group Module
module "asg" {
  source = "../../modules/asg"

  name_prefix             = local.name_prefix
  vpc_id                 = module.vpc.vpc_id
  vpc_cidr_block         = module.vpc.vpc_cidr_block
  private_subnet_ids     = module.vpc.private_subnet_ids
  target_group_arn       = module.alb.target_group_arn
  alb_security_group_id  = module.alb.alb_security_group_id

  instance_type      = var.instance_type
  key_name          = var.key_pair_name
  min_size          = var.asg_min_size
  max_size          = var.asg_max_size
  desired_capacity  = var.asg_desired_capacity

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    db_endpoint = module.rds.db_instance_endpoint
    redis_endpoint = module.elasticache.redis_endpoint
  }))

  tags = local.common_tags
}

# RDS Module
module "rds" {
  source = "../../modules/rds"

  name_prefix           = local.name_prefix
  vpc_id               = module.vpc.vpc_id
  private_subnet_ids   = module.vpc.private_subnet_ids
  allowed_security_groups = [module.asg.security_group_id]

  engine                = var.db_engine
  engine_version        = var.db_engine_version
  instance_class        = var.db_instance_class
  allocated_storage     = var.db_allocated_storage
  database_name         = var.db_name
  username             = var.db_username

  backup_retention_period = var.db_backup_retention_days
  multi_az                = var.db_multi_az
  deletion_protection     = var.db_deletion_protection

  tags = local.common_tags
}

# ElastiCache Module
module "elasticache" {
  source = "../../modules/elasticache"

  name_prefix           = local.name_prefix
  vpc_id               = module.vpc.vpc_id
  private_subnet_ids   = module.vpc.private_subnet_ids
  allowed_security_groups = [module.asg.security_group_id]

  node_type            = var.redis_node_type
  num_cache_nodes      = var.redis_num_nodes
  parameter_group_name = var.redis_parameter_group
  engine_version       = var.redis_engine_version

  tags = local.common_tags
}

# CloudWatch Module
module "cloudwatch" {
  source = "../../modules/cloudwatch"

  name_prefix = local.name_prefix

  # ALB monitoring
  alb_arn = module.alb.alb_arn
  target_group_arn = module.alb.target_group_arn

  # ASG monitoring
  autoscaling_group_name = module.asg.autoscaling_group_name
  scale_up_policy_arn    = module.asg.scale_up_policy_arn
  scale_down_policy_arn  = module.asg.scale_down_policy_arn

  # RDS monitoring
  db_instance_id = module.rds.db_instance_id

  # ElastiCache monitoring
  cache_cluster_id = module.elasticache.cache_cluster_id

  # Notification settings
  sns_topic_arn = var.sns_topic_arn

  tags = local.common_tags
}

# Backup Module
module "backup" {
  source = "../../modules/backup"

  name_prefix = local.name_prefix

  # Resources to backup
  rds_arn = module.rds.db_instance_arn
  asg_name = module.asg.autoscaling_group_name

  backup_retention_days = var.backup_retention_days
  backup_schedule       = var.backup_schedule

  tags = local.common_tags
}
