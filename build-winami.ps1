# Runs as packer's elevated PowerShell provisioner on the bake instance.
# Installs the full nteract Windows build toolchain and pre-clones
# nteract/nteract. Per-boot user-data on a winlab launched from this AMI
# only does sandbox-user creation, sshd + GitHub keys, tailscale, and a
# shallow `git pull` of the cloned repo.
#
# Order matters: chocolatey before packages, VS BuildTools before Rust
# (rustc's MSVC linker discovery uses the VS installer registry), pnpm +
# wasm-pack last (depend on nodejs being on PATH).

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'  # Invoke-WebRequest is glacial otherwise

# Retry wrapper. GitHub's asset CDN intermittently closes connections
# mid-transfer ("the connection was closed unexpectedly"). One blip used to
# kill an entire 11-min bake; three attempts with exponential backoff covers
# the typical hiccup without masking a real outage.
function Invoke-WebRequest-WithRetry {
    param([string]$Uri, [string]$OutFile, [int]$MaxAttempts = 3)
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
            return
        } catch {
            if ($i -eq $MaxAttempts) { throw }
            $sleep = [math]::Pow(2, $i)  # 2s, 4s, 8s
            Write-Host "WARN: download attempt $i/$MaxAttempts of $Uri failed ($_); retrying in $sleep s"
            Start-Sleep -Seconds $sleep
        }
    }
}

$logRoot = 'C:\ProgramData\nteract-bake'
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
Start-Transcript -Path "$logRoot\bake.log" -Append | Out-Null
"=== Windows AMI bake $(Get-Date -Format o) ==="

# --- 1. Chocolatey -----------------------------------------------------
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
$choco = 'C:\ProgramData\chocolatey\bin\choco.exe'
"chocolatey: $(& $choco --version 2>&1)"

# --- 2. Toolchain via choco -------------------------------------------
# rust-ms is the choco package that pulls rustup + a default stable-msvc
# toolchain. visualstudio2022buildtools provides cl.exe + Windows SDK +
# the linker that rustc finds via the VS installer registry. nasm is
# pulled in transitively by aws-lc-sys (zeromq -> aws-lc-sys).
& $choco install -y --no-progress git gh nasm rust-ms nodejs-lts
& $choco install -y --no-progress visualstudio2022buildtools `
  --package-parameters '"--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --quiet --norestart"'

# --- 3. OpenSSH server -------------------------------------------------
# Per-boot user-data still drops sandbox's GitHub keys into
# administrators_authorized_keys, but enabling the capability + setting
# default shell once at bake time saves ~30s on every winlab boot.
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
Set-Service -Name sshd -StartupType Automatic
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
  -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
  -PropertyType String -Force | Out-Null

# --- 4. Pixi (env manager used by #2274 reproductions) ---------------
$pixiZip = "$env:TEMP\pixi.zip"
Invoke-WebRequest-WithRetry -Uri 'https://github.com/prefix-dev/pixi/releases/latest/download/pixi-x86_64-pc-windows-msvc.zip' -OutFile $pixiZip
$pixiDir = 'C:\Program Files\pixi'
New-Item -ItemType Directory -Path $pixiDir -Force | Out-Null
Expand-Archive -Path $pixiZip -DestinationPath $pixiDir -Force
"pixi: $(& "$pixiDir\pixi.exe" --version 2>&1)"

# --- 5. Fold tool dirs into the *machine* PATH ------------------------
# VS Build Tools puts cl.exe / link.exe in a versioned dir; rustc finds
# them via the VS installer registry (vswhere) so they don't need PATH.
# What does need PATH: git, node/npm, NASM, pixi, chocolatey shims.
$machinePath = [System.Environment]::GetEnvironmentVariable('Path','Machine')
foreach ($p in 'C:\Program Files\Git\cmd','C:\Program Files\NASM','C:\Program Files\nodejs',$pixiDir,'C:\ProgramData\chocolatey\bin') {
    if ((Test-Path $p) -and ($machinePath -notlike "*$p*")) { $machinePath = "$machinePath;$p" }
}
[System.Environment]::SetEnvironmentVariable('Path', $machinePath, 'Machine')
$env:Path = $machinePath

# --- 6. wasm-pack + pnpm (binary downloads) ----------------------------
# Uses Invoke-WebRequest-WithRetry (defined above) - GitHub's release CDN
# was the original motivator for adding retries.
function Install-Github-Binary {
    param([string]$Url, [string]$ExeName, [string]$Tag)
    $tmp = "$env:TEMP\$Tag-dl"
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $archive = "$tmp\archive$([IO.Path]::GetExtension($Url))"
    Invoke-WebRequest-WithRetry -Uri $Url -OutFile $archive
    if ($archive.EndsWith('.tar.gz')) {
        & 'C:\Windows\System32\tar.exe' -xzf $archive -C $tmp
    } elseif ($archive.EndsWith('.zip')) {
        Expand-Archive -Path $archive -DestinationPath $tmp -Force
    } else {
        Copy-Item $archive "$tmp\$ExeName" -Force
    }
    $exe = Get-ChildItem $tmp -Recurse -Filter $ExeName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) { throw "$ExeName not found in $Url" }
    Copy-Item $exe.FullName -Destination "C:\ProgramData\chocolatey\bin\$ExeName" -Force
    "$ExeName -> C:\ProgramData\chocolatey\bin\$ExeName"
}

Install-Github-Binary -Tag 'wasm-pack' -ExeName 'wasm-pack.exe' `
    -Url 'https://github.com/rustwasm/wasm-pack/releases/download/v0.13.1/wasm-pack-v0.13.1-x86_64-pc-windows-msvc.tar.gz'

Install-Github-Binary -Tag 'pnpm' -ExeName 'pnpm.exe' `
    -Url 'https://github.com/pnpm/pnpm/releases/latest/download/pnpm-win32-x64.zip'

# --- 7. Pre-clone nteract/nteract --------------------------------------
# Public repo, HTTPS, no auth. Lives at C:\dev\nteract with sandbox having
# write access (the sandbox user is created per-boot but Administrators
# group always has full rights so per-boot ACL fixup is one icacls call).
$dev = 'C:\dev'
New-Item -ItemType Directory -Path $dev -Force | Out-Null
& git clone --depth 50 https://github.com/nteract/nteract.git "$dev\nteract"

# --- 8. Marker for bake verification -----------------------------------
Set-Content -Path "$logRoot\bake-done" -Value "bake done $(Get-Date -Format o)"
"=== Bake complete ==="
Stop-Transcript | Out-Null
