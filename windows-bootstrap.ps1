<powershell>
# Runs as EC2Launch v2 user_data on packer's bake instance. The only job is
# to expose WinRM-HTTPS on port 5986 so packer can connect; everything else
# (toolchain, repo prefetch) runs from packer's powershell provisioner via
# build-winami.ps1.
#
# Why a self-signed cert: the bake instance lives 30-45 minutes in a default
# VPC subnet. We don't have a CA-signed cert for the auto-assigned hostname
# and don't need one - packer connects with winrm_insecure=true.

$ErrorActionPreference = 'Continue'

# WinRM service running + automatic at boot
Set-Service -Name WinRM -StartupType Automatic
Start-Service WinRM

# Self-signed cert + HTTPS listener on 5986
$cert = New-SelfSignedCertificate -DnsName 'packer-bake' -CertStoreLocation Cert:\LocalMachine\My
winrm quickconfig -q
winrm set winrm/config/service/auth '@{Basic="true"}'
$listener = "@{Hostname=`"packer-bake`"; CertificateThumbprint=`"$($cert.Thumbprint)`"}"
winrm create "winrm/config/Listener?Address=*+Transport=HTTPS" $listener

# Open the firewall for WinRM HTTPS only. WinRM HTTP (5985) stays closed.
New-NetFirewallRule -DisplayName 'WinRM HTTPS' -Direction Inbound `
  -LocalPort 5986 -Protocol TCP -Action Allow -Profile Any | Out-Null
</powershell>
<persist>false</persist>
