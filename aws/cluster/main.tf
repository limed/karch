resource "aws_s3_bucket_object" "cluster-spec" {
  count  = "${var.enabled}"
  bucket = "${var.kops-state-bucket}"
  key    = "/karch-specs/${var.cluster-name}/master-cluster-spec.yml"

  content = <<EOF
${join("\n---\n", concat(
  list(data.template_file.cluster-spec.rendered),
  data.template_file.master-spec.*.rendered,
  data.template_file.bastion-spec.*.rendered,
  list(data.template_file.minion-spec.rendered)
))}
EOF

  // On destroy, remove the cluster first, if it exists
  provisioner "local-exec" {
    when    = "destroy"
    command = "(test -z \"$(kops --state=s3://${var.kops-state-bucket} get cluster | grep ${var.cluster-name})\" ) || kops --state=s3://${var.kops-state-bucket} delete cluster --yes ${var.cluster-name}"
  }

  depends_on = ["aws_route53_record.cluster-root"]
}

resource "null_resource" "kops-cluster" {
  count = "${var.enabled}"

  // Let's dump the cluster spec in a conf file
  provisioner "local-exec" {
    command = "echo \"${aws_s3_bucket_object.cluster-spec.content}\" > ${path.module}/${var.cluster-name}-cluster-spec.yml"
  }

  // Let's wait for our newly created DNS zone to propagate
  provisioner "local-exec" {
    command = <<EOF
      until test ! -z "$(dig NS @${aws_route53_zone.cluster.name_servers[0]} ${var.cluster-name} | grep "ANSWER SECTION")"
      do
        echo "DNS zone ${var.cluster-name} isn't available yet, retrying in 5s"
        sleep 5s
      done
EOF
  }

  // Let's register our Kops cluster into remote state
  provisioner "local-exec" {
    command = "kops --state=s3://${var.kops-state-bucket} create -f ${path.module}/${var.cluster-name}-cluster-spec.yml"
  }

  // Let's remove the cluster spec file from disk
  provisioner "local-exec" {
    command = "rm ${path.module}/${var.cluster-name}-cluster-spec.yml"
  }

  // Do not forget to add our public SSH key over there
  provisioner "local-exec" {
    command = "kops --state=s3://${var.kops-state-bucket} create secret --name ${var.cluster-name} sshpublickey admin -i ${var.admin-ssh-public-key-path}"
  }

  depends_on = ["aws_s3_bucket_object.cluster-spec"]
}

// Hook for other modules (like instance groups) to wait for the master to be available
resource "null_resource" "master-up" {
  count = "${var.enabled}"
  provisioner "local-exec" {
    command = <<EOF
      until kops --state=s3://${var.kops-state-bucket} validate cluster --name ${var.cluster-name}
      do
        echo "Cluster isn't available yet"
        sleep 5s
      done
EOF
  }

  depends_on = ["null_resource.kops-cluster"]
}

resource "null_resource" "kops-update" {
  count = "${var.enabled}"

  triggers {
    cluster_spec = "${aws_s3_bucket_object.cluster-spec.content}"
  }

  provisioner "local-exec" {
    command = "echo \"${aws_s3_bucket_object.cluster-spec.content}\" > ${path.module}/${var.cluster-name}-cluster-spec.yml"
  }

  provisioner "local-exec" {
    command = <<EOF
      set -e

      cleanup() {
        rm -f ${path.module}/${var.cluster-name}-cluster-spec.yml
      }
      trap cleanup EXIT

      kops --state=s3://${var.kops-state-bucket} \
        replace -f ${path.module}/${var.cluster-name}-cluster-spec.yml

      kops --state=s3://${var.kops-state-bucket} \
        update cluster ${var.cluster-name} --yes

      kops --state s3://${var.kops-state-bucket} \
        rolling-update cluster ${var.cluster-name} --yes \
        --master-interval=${var.master-update-interval}m --node-interval=${var.minion-update-interval}m
EOF
  }

  depends_on = ["null_resource.kops-cluster"]
}
