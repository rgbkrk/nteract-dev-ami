# Shared bits (packer block, aws_region, instance_type) live in
# packer.pkr.hcl.

# Windows Server 2022 base. AWS publishes maintained AMIs whose name
# pattern always points at the current patched build of the English Full
# Base image; most_recent picks the freshest.
data "amazon-ami" "win2022" {
  filters = {
    name                = "Windows_Server-2022-English-Full-Base-*"
    virtualization-type = "hvm"
    root-device-type    = "ebs"
  }
  owners      = ["amazon"]
  most_recent = true
  region      = var.aws_region
}

source "amazon-ebs" "windows" {
  ami_name      = "nteract-winlab-ami-{{timestamp}}"
  instance_type = var.instance_type
  region        = var.aws_region

  source_ami = data.amazon-ami.win2022.id

  # Connect via WinRM over HTTPS. Packer creates an ephemeral keypair,
  # attaches it to the bake instance, fetches the EC2-generated Administrator
  # password from the metadata endpoint, decrypts it with the keypair, and
  # uses it as the WinRM password. windows-bootstrap.ps1 enables WinRM.
  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = "30m"

  user_data_file = "windows-bootstrap.ps1"

  iam_instance_profile        = "packer-bake-profile"
  associate_public_ip_address = true

  # The toolchain install is heavy (VS 2022 BuildTools is ~3GB).
  # Allow plenty of polling headroom before AWS marks the snapshot timed out.
  aws_polling {
    delay_seconds = 30
    max_attempts  = 134
  }

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

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 100
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name    = "nteract-winlab-ami"
    Builder = "packer"
  }
}

build {
  sources = ["source.amazon-ebs.windows"]

  # Drop the install script onto the instance, then run it via PowerShell.
  # The execution policy is bypassed for this single invocation; the
  # restored default policy stays restricted in the baked AMI.
  provisioner "powershell" {
    script            = "build-winami.ps1"
    elevated_user     = "Administrator"
    elevated_password = build.Password
  }

  # Sysprep + EC2Launch generalize: hostname, SID, admin password, and the
  # ephemeral packer keypair all reset on first boot of a new instance.
  # Without this, every winlab launched from the AMI would inherit the
  # bake instance's hostname and SID, and Tailscale would see them as
  # the same node.
  provisioner "powershell" {
    inline = [
      "C:\\ProgramData\\Amazon\\EC2Launch\\Scripts\\ResetHasRunFiles.ps1",
      "C:\\ProgramData\\Amazon\\EC2Launch\\Scripts\\InitializeInstance.ps1 -Schedule",
      "C:\\ProgramData\\Amazon\\EC2Launch\\Scripts\\SysprepInstance.ps1 -NoShutdown",
    ]
  }
}
