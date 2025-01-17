output "rancher_admin_password" {
  value     = local.rancher_password
  sensitive = true
}

output "rancher_url" {
  value = local.install_rancher && contains(rancher2_bootstrap.admin, "0") ? rancher2_bootstrap.admin.0.url : null
}

output "rancher_token" {
  value     = local.install_rancher ? rancher2_bootstrap.admin.0.token : null
  sensitive = true
}

output "rancher_endpoint" {
  value = contains(aws_lb.lb, "0") ? aws_lb.lb.0.dns_name : null
}

output "internal_lb" {
  value = aws_lb.server-lb.dns_name
}
