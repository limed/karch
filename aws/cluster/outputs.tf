# Lifecycle hooks
output "master-up" {
  value = "${element(concat(null_resource.master-up.*.id, list("")), 0)}"
}

output "cluster-created" {
  value = "${element(concat(null_resource.kops-cluster.*.id, list("")), 0)}"
}

# DNS zone for the cluster subdomain
output "route53-cluster-zone-id" {
  value = "${aws_route53_zone.cluster.id}"
}

output "vpc-id" {
  value = "${var.vpc-id}"
}

// Nodes security groups (to direct ELB traffic to hostPort pods)
output "nodes-sg" {
  value = "${element(split("/", data.aws_security_group.nodes.arn), 1)}"
}
