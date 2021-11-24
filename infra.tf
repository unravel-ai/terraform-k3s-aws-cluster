#############################
### Access Control
#############################

resource "aws_security_group" "ingress" {
  name   = "${local.name}-k3s-ingress"
  vpc_id = data.aws_vpc.default.id
  tags = {
    Name = "${local.name}-k3s-ingress"
  }
}

resource "aws_security_group_rule" "ingress_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "TCP"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.ingress.id
}

resource "aws_security_group_rule" "ingress_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "TCP"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.ingress.id
}

resource "aws_security_group_rule" "ingress_self" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.ingress.id
}

resource "aws_security_group_rule" "ingress_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.ingress.id
}

resource "aws_security_group" "self" {
  name   = "${local.name}-k3s-self"
  vpc_id = data.aws_vpc.default.id
  tags = {
    Name = "${local.name}-k3s-self"
  }
}

resource "aws_security_group_rule" "self_self" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.self.id
}

resource "aws_security_group_rule" "self_k3s_server" {
  type              = "ingress"
  from_port         = 6443
  to_port           = 6443
  protocol          = "TCP"
  cidr_blocks       = local.private_subnets_cidr_blocks
  security_group_id = aws_security_group.self.id
}

resource "aws_security_group" "database" {
  count  = local.deploy_rds
  name   = "${local.name}-database"
  vpc_id = data.aws_vpc.default.id
}

resource "aws_security_group_rule" "database_self" {
  count             = local.deploy_rds
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "TCP"
  self              = true
  security_group_id = aws_security_group.database[count.index].id
}

resource "aws_security_group_rule" "database_egress_all" {
  count             = local.deploy_rds
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.database[count.index].id
}

#############################
### Create Nodes
#############################
resource "aws_launch_template" "k3s_server" {
  name_prefix   = "${local.name}-server"
  image_id      = local.server_image_id
  instance_type = local.server_instance_type
  user_data     = data.template_cloudinit_config.k3s_server.rendered

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      encrypted   = true
      volume_type = "gp2"
      volume_size = "10"
    }
  }

  iam_instance_profile {
    name = "apptr_instance_iam"
  }

  network_interfaces {
    delete_on_termination = true
    security_groups       = concat([aws_security_group.ingress.id, aws_security_group.self.id], var.extra_server_security_groups)
  }

  tags = {
    Name = "${local.name}-server"
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${local.name}-server"
    }
  }
}

resource "aws_launch_template" "k3s_agent" {
  for_each = {
    for agent_spec in local.agent_specs : agent_spec.name => agent_spec
  }
  name_prefix   = "${local.name}-agent-${each.key}"
  image_id      = data.aws_ami.agent_ami[each.key].id
  instance_type = each.value.type
  user_data     = data.template_cloudinit_config.k3s_agent[each.key].rendered

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      encrypted   = true
      volume_type = "gp2"
      volume_size = "25"
    }
  }

  network_interfaces {
    delete_on_termination = true
    security_groups       = concat([aws_security_group.ingress.id, aws_security_group.self.id], var.extra_agent_security_groups)
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge({
      Name = "${local.name}-agent-${each.key}"
    }, each.value.tags)
  }
}

resource "aws_autoscaling_group" "k3s_server" {
  name_prefix         = "${local.name}-server"
  desired_capacity    = local.server_node_count
  max_size            = local.server_node_count
  min_size            = local.server_node_count
  vpc_zone_identifier = local.private_subnets

  target_group_arns = [
    aws_lb_target_group.server-6443.arn
  ]

  launch_template {
    id      = aws_launch_template.k3s_server.id
    version = "$Latest"
  }

  depends_on = [aws_rds_cluster_instance.k3s]
}

resource "aws_autoscaling_group" "k3s_agent" {
  for_each = {
    for agent_spec in local.agent_specs : agent_spec.name => agent_spec
  }
  name_prefix      = "${local.name}-agent-${each.key}"
  desired_capacity = each.value.capacity.desired
  max_size         = each.value.capacity.max
  min_size         = each.value.capacity.min

  vpc_zone_identifier = local.private_subnets


  target_group_arns = local.create_external_nlb != 0 ? [
    aws_lb_target_group.agent-80.0.arn,
    aws_lb_target_group.agent-443.0.arn
  ] : []


  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = each.value.on_demand_base_capacity
      on_demand_percentage_above_base_capacity = each.value.on_demand_percentage_above_base_capacity
      spot_max_price                           = each.value.spot_max_price
    }

    launch_template {

      launch_template_specification {
        launch_template_id = aws_launch_template.k3s_agent[each.key].id
        version            = "$Latest"
      }

    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name}-agent-${each.key}"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = each.value.tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

}

#############################
### Create Database
#############################
resource "aws_db_subnet_group" "private" {
  count       = local.deploy_rds
  name_prefix = "${local.name}-private"
  subnet_ids  = local.private_subnets
}

resource "aws_rds_cluster_parameter_group" "k3s" {
  count       = local.deploy_rds
  name_prefix = "${local.name}-"
  description = "Force SSL for aurora-postgresql10.7"
  family      = "aurora-postgresql10"

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }
}

resource "aws_rds_cluster" "k3s" {
  count                           = local.deploy_rds
  cluster_identifier_prefix       = "${local.name}-"
  engine                          = "aurora-postgresql"
  engine_mode                     = "provisioned"
  engine_version                  = "10.7"
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.k3s.0.name
  availability_zones              = local.aws_azs
  database_name                   = local.db_name
  master_username                 = local.db_user
  master_password                 = local.db_pass
  preferred_maintenance_window    = "fri:11:21-fri:11:51"
  db_subnet_group_name            = aws_db_subnet_group.private.0.id
  vpc_security_group_ids          = [aws_security_group.database[count.index].id]
  storage_encrypted               = true

  preferred_backup_window   = "11:52-19:52"
  backup_retention_period   = 30
  copy_tags_to_snapshot     = true
  deletion_protection       = false
  skip_final_snapshot       = local.skip_final_snapshot ? true : false
  final_snapshot_identifier = local.skip_final_snapshot ? null : "${local.name}-final-snapshot"
}

resource "aws_rds_cluster_instance" "k3s" {
  count                = local.db_node_count
  identifier_prefix    = "${local.name}-${count.index}"
  cluster_identifier   = aws_rds_cluster.k3s.0.id
  engine               = "aurora-postgresql"
  instance_class       = local.db_instance_type
  db_subnet_group_name = aws_db_subnet_group.private.0.id
}

#############################
### Create Public Rancher DNS
#############################
resource "aws_route53_record" "rancher" {
  count    = local.install_rancher ? local.create_external_nlb : 0
  zone_id  = data.aws_route53_zone.dns_zone[count.index].zone_id
  name     = "${local.name}.${local.domain}"
  type     = "CNAME"
  ttl      = 30
  records  = [aws_lb.lb.0.dns_name]
  provider = aws.r53
}
