module "back_end" {
  source = "../../aws_instance"

  aws_profile       = "${var.aws_profile}"
  aws_region        = "${var.aws_region}"
  aws_vpc_name      = "${var.aws_vpc_name}"
  aws_ssh_key_id    = "${var.aws_ssh_key_id}"
  aws_instance_type = "${var.aws_instance_type}"
  platform          = "${var.platform}"
  name              = "backend-omnibus-tiered-fresh-install"
}

module "front_end" {
  source = "../../aws_instance"

  aws_profile       = "${var.aws_profile}"
  aws_region        = "${var.aws_region}"
  aws_vpc_name      = "${var.aws_vpc_name}"
  aws_ssh_key_id    = "${var.aws_ssh_key_id}"
  aws_instance_type = "${var.aws_instance_type}"
  platform          = "${var.platform}"
  name              = "frontend-omnibus-tiered-fresh-install"
}

# generate static hosts configuration
data "template_file" "hosts_config" {
  template = "${file("${path.module}/templates/hosts.tpl")}"

  vars {
    back_end_ip    = "${module.back_end.private_ipv4_address}"
    front_end_ip   = "${module.front_end.private_ipv4_address}"
    back_end_ipv6  = "${module.back_end.public_ipv6_address}"
    front_end_ipv6 = "${module.front_end.public_ipv6_address}"
  }
}

# generate chef-server.rb configuration
data "template_file" "chef_server_config" {
  template = "${file("${path.module}/templates/chef-server.rb.tpl")}"

  vars {
    back_end_ipv6  = "${module.back_end.public_ipv6_address}"
    front_end_ipv6 = "${module.front_end.public_ipv6_address}"
  }
}

# update back-end chef server
resource "null_resource" "back_end_config" {
  # provide some connection info
  connection {
    type = "ssh"
    user = "${module.back_end.ssh_username}"
    host = "${module.back_end.public_ipv4_dns}"
  }

  provisioner "file" {
    content     = "${data.template_file.hosts_config.rendered}"
    destination = "/tmp/hosts"
  }

  provisioner "file" {
    content     = "${data.template_file.chef_server_config.rendered}"
    destination = "/tmp/chef-server.rb"
  }

  provisioner "file" {
    source      = "${path.module}/files/dhparam.pem"
    destination = "/tmp/dhparam.pem"
  }

  provisioner "remote-exec" {
    inline = [
      "set -evx",
      "curl -vo /tmp/chef-server.deb https://packages.chef.io/files/unstable/chef-server/${var.build_version}/ubuntu/16.04/chef-server-core_${var.build_version}-1_amd64.deb",
      "sudo dpkg -iEG /tmp/chef-server.deb",
      "sudo chown root:root /tmp/chef-server.rb",
      "sudo chown root:root /tmp/dhparam.pem",
      "sudo chown root:root /tmp/hosts",
      "sudo mv /tmp/chef-server.rb /etc/opscode",
      "sudo mv /tmp/dhparam.pem /etc/opscode",
      "sudo mv /tmp/hosts /etc/hosts",
      "sudo chef-server-ctl reconfigure --chef-license=accept",
      "sleep 30",
      "sudo chef-server-ctl user-create janedoe Jane Doe janed@example.com abc123 --filename /tmp/janedoe.pem",
      "sudo chef-server-ctl org-create 4thcoffee 'Fourth Coffee, Inc.' --association_user janedoe --filename /tmp/4thcoffee-validator.pem",
      "sudo tar -C /etc -czf /tmp/opscode.tgz opscode",
      "scp -o 'UserKnownHostsFile=/dev/null' -o 'StrictHostKeyChecking=no' /tmp/opscode.tgz ${module.back_end.ssh_username}@${module.front_end.public_ipv4_dns}:/tmp",
    ]
  }
}

# update front-end chef server
resource "null_resource" "front_end_config" {
  depends_on = ["null_resource.back_end_config"]

  # provide some connection info
  connection {
    type = "ssh"
    user = "${module.front_end.ssh_username}"
    host = "${module.front_end.public_ipv4_dns}"
  }

  provisioner "remote-exec" {
    inline = [
      "set -evx",
      "sudo tar -C /etc -xzf /tmp/opscode.tgz",
      "curl -vo /tmp/chef-server.deb https://packages.chef.io/files/unstable/chef-server/${var.build_version}/ubuntu/16.04/chef-server-core_${var.build_version}-1_amd64.deb",
      "sudo dpkg -iEG /tmp/chef-server.deb",
      "sudo chef-server-ctl reconfigure --chef-license=accept",
      "sleep 120",
      "sudo chef-server-ctl test",
    ]

    # FIXME 20190911 - fix to run all tests rather than just smoke once tiered pedant testing is supported
    # "sudo chef-server-ctl test -J pedant.xml --all --compliance-proxy-tests"
  }
}
