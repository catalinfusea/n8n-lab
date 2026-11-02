# ============================================================
# n8n - STANDALONE VM DEPLOYMENT (v2, hardened)
# Platform: Windows 11 + VMware Workstation + Vagrant (vagrant-vmware-desktop)
# Guest:    Ubuntu 24.04 LTS (bento/ubuntu-24.04)
# Services: Docker + n8n (pinned 2.x) + PostgreSQL 16
#
# Changes vs v1:
#  - .env is generated ONCE and never overwritten (Postgres password and
#    N8N_ENCRYPTION_KEY must stay stable across runs)
#  - n8n image pinned (no :latest - n8n 3.0 is in beta with breaking changes)
#  - Portainer removed (docker.sock mount = root in guest)
#  - No custom forwarded ports; n8n published on guest 127.0.0.1 only,
#    access via SSH tunnel
#  - /vagrant synced folder disabled (guest cannot write to the host folder)
#  - SSH password auth disabled in guest (bento box ships vagrant/vagrant)
#  - n8n telemetry and version checks disabled
#  - vmnetnat.conf backed up before 'vagrant up' and compared afterwards
#    (vagrant-vmware-desktop restarts the VMware NAT service)
#
# Keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI).
# ============================================================

$ErrorActionPreference = "Stop"

# ---- Settings -------------------------------------------------
$ProjectPath  = "G:\AI\AI pipelines\n8n"
# Pinned n8n version. Check the current stable 2.x before changing:
# https://docs.n8n.io/changelog/  (do NOT jump to 3.x without reading the
# v3.0 breaking changes + Migration Report)
$N8nVersion   = "2.45.7"
$VmMemoryMB   = 4096
$VmCpus       = 2
$VmNatConf    = "C:\ProgramData\VMware\vmnetnat.conf"
# ---------------------------------------------------------------

if ($N8nVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw "N8nVersion must be an exact x.y.z version, got '$N8nVersion'."
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "       n8n STANDALONE VM INSTALLER (v2)"
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------
# 1. CHECK PREREQUISITES
# ------------------------------------------------------------
Write-Host "[1/7] Checking prerequisites..." -ForegroundColor Yellow

if (-not (Get-Command vagrant -ErrorAction SilentlyContinue)) {
    throw "Vagrant not found in PATH. Install Vagrant first."
}
Write-Host "Vagrant: OK" -ForegroundColor Green

# vmware.exe is usually not in PATH; check the Vagrant VMware Utility service instead
$Util = Get-Service -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like '*vagrant*vmware*' -or $_.DisplayName -like '*Vagrant*VMware*' } |
    Select-Object -First 1
if (-not $Util) {
    throw "Vagrant VMware Utility service not found. Install it (required by vagrant-vmware-desktop)."
}
if ($Util.Status -ne 'Running') {
    throw "Vagrant VMware Utility service '$($Util.Name)' is $($Util.Status). Start it first."
}
Write-Host "Vagrant VMware Utility ($($Util.Name)): Running" -ForegroundColor Green

# ------------------------------------------------------------
# 2. CHECK VMWARE PROVIDER PLUGIN
# ------------------------------------------------------------
Write-Host ""
Write-Host "[2/7] Checking Vagrant VMware provider..." -ForegroundColor Yellow

$Plugins = & vagrant plugin list 2>&1
if (($Plugins -join "`n") -notmatch "vagrant-vmware-desktop") {
    Write-Host "Installing vagrant-vmware-desktop plugin..." -ForegroundColor Cyan
    & vagrant plugin install vagrant-vmware-desktop
    if ($LASTEXITCODE -ne 0) { throw "VMware plugin installation failed." }
}
else {
    Write-Host "vagrant-vmware-desktop already installed." -ForegroundColor Green
}

# ------------------------------------------------------------
# 3. CREATE PROJECT DIRECTORY
# ------------------------------------------------------------
Write-Host ""
Write-Host "[3/7] Preparing project directory..." -ForegroundColor Yellow

New-Item -ItemType Directory -Path $ProjectPath -Force | Out-Null
Set-Location $ProjectPath
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ------------------------------------------------------------
# 4. SECRETS (.env) - CREATED ONCE, NEVER OVERWRITTEN
# ------------------------------------------------------------
Write-Host ""
Write-Host "[4/7] Checking secrets (.env)..." -ForegroundColor Yellow

function New-HexSecret {
    $Bytes = New-Object byte[] 32
    $RNG = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $RNG.GetBytes($Bytes)
        return (($Bytes | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally { $RNG.Dispose() }
}

$EnvPath = Join-Path $ProjectPath ".env"
if (Test-Path -LiteralPath $EnvPath) {
    Write-Host ".env exists - keeping it (secrets are NOT regenerated)." -ForegroundColor Green
}
else {
    $EnvContent = "POSTGRES_PASSWORD=$(New-HexSecret)`nN8N_ENCRYPTION_KEY=$(New-HexSecret)`n"
    [System.IO.File]::WriteAllText($EnvPath, $EnvContent, $Utf8NoBom)

    # Restrict .env to the current user only (no inherited ACEs)
    & icacls "$EnvPath" /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "icacls failed - check .env permissions manually." }

    Write-Host ".env created. BACK IT UP: without N8N_ENCRYPTION_KEY the stored n8n credentials cannot be decrypted." -ForegroundColor Cyan
}

# ------------------------------------------------------------
# 5. VAGRANTFILE
# ------------------------------------------------------------
Write-Host ""
Write-Host "[5/7] Writing Vagrantfile..." -ForegroundColor Yellow

# Single-quoted here-string: PowerShell does not expand $ (bash variables stay intact).
$VagrantContent = @'
Vagrant.configure("2") do |config|
  config.vm.box = "bento/ubuntu-24.04"
  config.vm.hostname = "n8n-server"
  config.vm.boot_timeout = 600
  config.vm.box_check_update = false

  # Guest must not have write access to the host project folder
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # No custom forwarded ports. n8n (and the host's Ollama) are reached through
  # an SSH tunnel: run Start-n8n-Tunnel.ps1 from this folder.

  config.vm.provider "vmware_desktop" do |v|
    v.vmx["memsize"] = "__VM_MEMORY__"
    v.vmx["numvcpus"] = "__VM_CPUS__"
    v.vmx["displayname"] = "AI-n8n-Server"
  end

  config.vm.provision "shell", name: "base", inline: <<-SHELL
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    APT_OPTS='-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold'

    apt-get update
    apt-get upgrade -y $APT_OPTS
    apt-get install -y $APT_OPTS ca-certificates curl

    # --- SSH hardening: key-only (bento box has password vagrant/vagrant) ---
    # 00- prefix so it wins over 50-cloud-init.conf (first match wins in sshd)
    cat > /etc/ssh/sshd_config.d/00-n8n-hardening.conf <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
GatewayPorts clientspecified
EOF
    # Ubuntu 24.04 uses ssh.socket: /run/sshd only exists once ssh.service ran,
    # and 'sshd -t' fails without it
    install -d -m 0755 -o root -g root /run/sshd
    sshd -t
    systemctl restart ssh || systemctl restart sshd || true

    # --- Docker CE from the official repo ---
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    apt-get update
    apt-get install -y $APT_OPTS docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    usermod -aG docker vagrant

    # Target dir writable by 'vagrant' so the file provisioner can upload
    mkdir -p /opt/n8n
    chown -R vagrant:vagrant /opt/n8n
  SHELL

  config.vm.provision "file", source: "docker-compose.yml", destination: "/opt/n8n/docker-compose.yml"
  config.vm.provision "file", source: ".env", destination: "/opt/n8n/.env"

  config.vm.provision "shell", name: "n8n", inline: <<-SHELL
    set -euo pipefail
    cd /opt/n8n
    chown root:root .env docker-compose.yml
    chmod 600 .env

    docker compose config --quiet
    docker compose pull
    docker compose up -d

    # Wait for n8n on guest loopback (warn only, do not fail provisioning)
    for i in $(seq 1 60); do
      if curl -fsS -o /dev/null http://127.0.0.1:5678/; then
        echo "n8n is up on 127.0.0.1:5678 (guest)."; break
      fi
      sleep 5
      if [ "$i" -eq 60 ]; then echo "WARNING: n8n did not answer after 5 min - check: docker compose -f /opt/n8n/docker-compose.yml logs n8n"; fi
    done

    echo "Listening sockets for 5678 (must be 127.0.0.1 only):"
    ss -ltnp | grep ':5678' || true
  SHELL
end
'@

$VagrantContent = $VagrantContent.Replace("__VM_MEMORY__", [string]$VmMemoryMB).Replace("__VM_CPUS__", [string]$VmCpus)
[System.IO.File]::WriteAllText((Join-Path $ProjectPath "Vagrantfile"), $VagrantContent, $Utf8NoBom)

# ------------------------------------------------------------
# 6. DOCKER COMPOSE
# ------------------------------------------------------------
Write-Host ""
Write-Host "[6/7] Writing docker-compose.yml (n8n $N8nVersion)..." -ForegroundColor Yellow

# ${...} below are Docker Compose variables read from .env, not PowerShell.
$ComposeContent = @'
services:
  postgres:
    image: postgres:16
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: n8n
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: n8n
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n -d n8n"]
      interval: 10s
      timeout: 5s
      retries: 10

  n8n:
    image: docker.n8n.io/n8nio/n8n:__N8N_VERSION__
    container_name: n8n
    restart: unless-stopped
    ports:
      # guest loopback only - not reachable from VMnet8
      - "127.0.0.1:5678:5678"
    extra_hosts:
      # resolves to the guest docker0 IP; Ollama (Windows host) is reached via
      # the reverse SSH tunnel started by Start-n8n-Tunnel.ps1
      - "host.docker.internal:host-gateway"
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_USER: n8n
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_HOST: localhost
      N8N_PORT: 5678
      N8N_PROTOCOL: http
      WEBHOOK_URL: http://localhost:5678/
      GENERIC_TIMEZONE: Europe/Bucharest
      TZ: Europe/Bucharest
      N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS: "true"
      N8N_DIAGNOSTICS_ENABLED: "false"
      N8N_VERSION_NOTIFICATIONS_ENABLED: "false"
    volumes:
      - n8n_data:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  postgres_data:
  n8n_data:
'@

$ComposeContent = $ComposeContent.Replace("__N8N_VERSION__", $N8nVersion)
[System.IO.File]::WriteAllText((Join-Path $ProjectPath "docker-compose.yml"), $ComposeContent, $Utf8NoBom)

# ---- Tunnel helper: n8n UI (-L) + host Ollama for the guest (-R) ----
$TunnelContent = @'
# Start-n8n-Tunnel.ps1 - run on the Windows host. Keep the window open; Ctrl+C closes the tunnel.
#   -L 5678 : n8n UI        -> http://localhost:5678
#   -R      : host Ollama   -> reachable in the n8n container as http://host.docker.internal:11434
$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

if (-not (Test-NetConnection -ComputerName 127.0.0.1 -Port 11434 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    throw "Nothing listens on 127.0.0.1:11434 on this host. Start Ollama first."
}

$Out = (& vagrant ssh -c 'ip -4 -o addr show docker0' 2>$null) -join ' '
if ($Out -notmatch 'inet (\d{1,3}(?:\.\d{1,3}){3})/') {
    throw "Could not read the docker0 IP from the guest. Is the VM running (vagrant up)?"
}
$Docker0 = $Matches[1]

Write-Host "n8n UI : http://localhost:5678"
Write-Host "Ollama : http://host.docker.internal:11434 (inside n8n, via ${Docker0}:11434)"
Write-Host "Tunnel open - no further output is normal. Ctrl+C to close."
& vagrant ssh -- -L 5678:127.0.0.1:5678 -R "${Docker0}:11434:127.0.0.1:11434" -N
'@
[System.IO.File]::WriteAllText((Join-Path $ProjectPath "Start-n8n-Tunnel.ps1"), $TunnelContent, $Utf8NoBom)

# ------------------------------------------------------------
# 7. VALIDATE & (OPTIONALLY) START
# ------------------------------------------------------------
Write-Host ""
Write-Host "[7/7] Validating Vagrant configuration..." -ForegroundColor Yellow

& vagrant validate
if ($LASTEXITCODE -ne 0) { throw "Vagrant configuration validation failed." }

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "       PROJECT FILES READY"
Write-Host "==========================================" -ForegroundColor Green
Write-Host "Project : $ProjectPath"
Write-Host "VM      : $VmCpus vCPU / $VmMemoryMB MB RAM"
Write-Host "n8n     : $N8nVersion (guest 127.0.0.1:5678 only)"
Write-Host ""
Write-Host "WARNING: 'vagrant up' restarts the VMware NAT service." -ForegroundColor Yellow
Write-Host "Running VMs on VMnet8 (incl. pfSense WAN) may lose connectivity briefly," -ForegroundColor Yellow
Write-Host "and existing NAT port forwards may be rewritten. Best: stop the lab first." -ForegroundColor Yellow
Write-Host ""

$Answer = Read-Host "Start VM installation now? (Y/N)"
if ($Answer -notmatch '^[Yy]$') {
    Write-Host ""
    Write-Host "Installation postponed. To start later:"
    Write-Host "  cd `"$ProjectPath`""
    Write-Host "  vagrant up --provider=vmware_desktop"
    return
}

# Backup vmnetnat.conf before Vagrant touches the NAT service
$NatBackup = $null
if (Test-Path -LiteralPath $VmNatConf) {
    $NatBackup = Join-Path $ProjectPath ("vmnetnat.conf.bak-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    Copy-Item -LiteralPath $VmNatConf -Destination $NatBackup
    Write-Host "vmnetnat.conf backed up to: $NatBackup" -ForegroundColor Green
}
else {
    Write-Warning "$VmNatConf not found - skipping NAT config backup. Set `$VmNatConf if it lives elsewhere."
}

& vagrant up --provider=vmware_desktop
$UpExit = $LASTEXITCODE

if ($NatBackup) {
    Write-Host ""
    Write-Host "vmnetnat.conf changes made during 'vagrant up' (<= removed, => added):" -ForegroundColor Yellow
    $Diff = Compare-Object (Get-Content -LiteralPath $NatBackup) (Get-Content -LiteralPath $VmNatConf)
    if ($Diff) { $Diff | Format-Table -AutoSize } else { Write-Host "  (no changes)" }
}

Write-Host ""
Write-Host "Host listeners on 5678 (should be empty unless a tunnel is open):"
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -eq 5678 | Format-Table LocalAddress, LocalPort, OwningProcess -AutoSize

if ($UpExit -ne 0) {
    Write-Warning "vagrant up returned exit code $UpExit."
}
else {
    Write-Host ""
    Write-Host "Access n8n:" -ForegroundColor Green
    Write-Host "  1) cd `"$ProjectPath`"; .\Start-n8n-Tunnel.ps1"
    Write-Host "     (no output is normal - keep the window open; Ctrl+C closes the tunnel)"
    Write-Host "  2) Browser:         http://localhost:5678"
    Write-Host "  3) Ollama in n8n:   Ollama Chat Model -> Base URL http://host.docker.internal:11434"
}
