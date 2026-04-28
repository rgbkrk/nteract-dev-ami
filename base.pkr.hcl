# Shared bits (packer block, aws_region, instance_type) live in
# packer.pkr.hcl so windows.pkr.hcl can reuse them without duplicating.

source "amazon-ebs" "base" {
  ami_name      = "nteract-dev-ami-{{timestamp}}"
  instance_type = var.instance_type
  region        = var.aws_region

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      virtualization-type = "hvm"
    }
    owners      = ["099720109477"] # Canonical
    most_recent = true
  }

  ssh_username                = "ubuntu"
  associate_public_ip_address = true
  iam_instance_profile        = "packer-bake-profile"

  # Large root volume snapshots routinely take >30min (packer default) to flip
  # to available. Give AWS enough headroom that a healthy bake doesn't look
  # like a failure.
  aws_polling {
    delay_seconds = 30
    max_attempts  = 134
  }

  # Auto-discover the default VPC and any available subnet in it.
  vpc_filter {
    filters = {
      "isDefault" = "true"
    }
  }
  subnet_filter {
    filters = {
      "state" = "available"
    }
    most_free = true
    random    = false
  }

  # build-ami.sh runs as cloud-init user_data on the bake instance.
  user_data_file = "build-ami.sh"

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 200
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name    = "nteract-dev-ami"
    Builder = "packer"
  }
}

build {
  sources = ["source.amazon-ebs.base"]

  # Wait for cloud-init (running build-ami.sh) to finish, then confirm success.
  provisioner "shell" {
    inline = [
      "cloud-init status --wait || true",
      "test -f /var/log/cloud-init-ami-build-done",
    ]
  }
}
