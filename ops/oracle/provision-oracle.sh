#!/usr/bin/env bash
#
# Prepare an Oracle Cloud Always Free instance to run n8n.
#
#   Shape:  VM.Standard.A1.Flex — 1 OCPU / 6 GB is plenty (you may use up to
#           4 OCPU / 24 GB across all A1 instances, always free)
#   Image:  Canonical Ubuntu 22.04 or 24.04 (aarch64)
#   Boot:   50 GB (200 GB total block storage is free)
#
# Run ON the instance:
#   ssh ubuntu@<ip> 'bash -s' < ops/oracle/provision-oracle.sh
#
# Idempotent. Handles the two things that make Oracle different from every
# other VPS, both of which fail silently-ish and cost an evening:
#
#   1. Oracle's Ubuntu images ship a restrictive iptables ruleset that
#      persists across reboots. Opening 80/443 in the VCN Security List is
#      NOT enough — the packet reaches the box and is dropped locally. The
#      symptom is a Let's Encrypt challenge that times out while `curl
#      localhost` works fine.
#   2. The REJECT rule sits at the end of the INPUT chain, so rules must be
#      INSERTED above it, not appended after.
set -euo pipefail

APP_DIR="/opt/acq"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
skip() { printf '    \033[2m(already done: %s)\033[0m\n' "$1"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }

step "Host"
echo "    $(uname -m) · $(nproc) vCPU · $(free -m | awk '/^Mem:/ {print $2}') MB RAM"
if [ "$(uname -m)" = "aarch64" ]; then
  echo "    arm64 — the n8n image is multi-arch, so this is supported."
fi

# ---------------------------------------------------------------------
step "Swap"
# Ampere A1 with 6 GB does not strictly need it, but swap costs nothing and
# turns a memory spike into a slow minute rather than an OOM kill.
if swapon --show | grep -q '/swapfile'; then
  skip "swapfile active"
else
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -qw vm.swappiness=10
  grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
  echo "    2 GB swapfile created"
fi

# ---------------------------------------------------------------------
step "Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg iptables-persistent \
                       postgresql-client fail2ban unattended-upgrades >/dev/null
echo "    base packages present"

# ---------------------------------------------------------------------
step "Docker"
if command -v docker >/dev/null 2>&1; then
  skip "docker $(docker --version | awk '{print $3}' | tr -d ,)"
else
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  # dpkg --print-architecture resolves to arm64 here; the Docker repo has it.
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
                         docker-buildx-plugin docker-compose-plugin >/dev/null
  systemctl enable --now docker
  echo "    docker installed"
fi

if [ ! -f /etc/docker/daemon.json ]; then
  cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON
  systemctl restart docker
  echo "    container log rotation capped at 30 MB each"
else
  skip "/etc/docker/daemon.json exists"
fi

# ---------------------------------------------------------------------
step "Firewall — the Oracle-specific part"
#
# Oracle's Ubuntu image drops everything not explicitly allowed, via an
# iptables ruleset restored at boot by netfilter-persistent. The rules must go
# ABOVE the trailing REJECT, hence -I with an explicit position rather than -A.
#
# Note this deliberately does NOT open 5678. The n8n UI stays on loopback and
# is reached through an SSH tunnel.
opened=0
for port in 80 443; do
  if iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
    skip "tcp/$port already allowed"
  else
    # Insert above the REJECT rule if there is one, else append.
    reject_line="$(iptables -L INPUT --line-numbers -n 2>/dev/null \
                    | awk '/REJECT/ {print $1; exit}')"
    if [ -n "$reject_line" ]; then
      iptables -I INPUT "$reject_line" -p tcp --dport "$port" -j ACCEPT
    else
      iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
    fi
    echo "    opened tcp/$port"
    opened=1
  fi
done

if [ "$opened" -eq 1 ]; then
  netfilter-persistent save >/dev/null 2>&1 || iptables-save > /etc/iptables/rules.v4
  echo "    rules saved — they now survive a reboot"
fi

systemctl enable --now fail2ban >/dev/null 2>&1 || true

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF

install -d -o ubuntu -g ubuntu "$APP_DIR" 2>/dev/null || install -d "$APP_DIR"
usermod -aG docker ubuntu 2>/dev/null || true

# ---------------------------------------------------------------------
step "Outbound SMTP"
# Mail leaves via Zoho on 587 with authentication, not direct-to-MX on 25.
# Checked here because discovering it while debugging a silent send costs far
# more than checking now.
if timeout 5 bash -c 'cat < /dev/null > /dev/tcp/smtp.zoho.com/587' 2>/dev/null; then
  echo "    port 587 to smtp.zoho.com: reachable"
else
  echo "    WARNING: smtp.zoho.com:587 unreachable — outbound mail will fail."
fi

# ---------------------------------------------------------------------
step "Done"
ip="$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || echo '<instance IP>')"
cat <<EOF

  Ready. Nothing is running yet.

  $(free -m | awk '/^Mem:/ {printf "RAM  %s MB total, %s MB used", $2, $3}')
  $(df -h / | awk 'NR==2 {printf "Disk %s of %s used", $3, $2}')

  STILL TO DO IN THE ORACLE CONSOLE — the host firewall above is only half:
    Networking -> Virtual Cloud Networks -> your VCN -> Security Lists
    -> Default Security List -> Add Ingress Rules
       Source 0.0.0.0/0  ·  TCP  ·  destination port 80
       Source 0.0.0.0/0  ·  TCP  ·  destination port 443
    Both layers must allow the port. Neither alone is enough.

  Then, from your laptop:
    1. DNS: A record for your N8N_HOST -> $ip  (wait for it to resolve)
    2. ~/.ssh/config:
         Host acq
           HostName $ip
           User ubuntu
    3. Copy the repo up and start it:
         rsync -az --exclude .git --exclude node_modules ./ acq:$APP_DIR/
         ssh acq "cd $APP_DIR && docker compose -f ops/docker-compose.n8n.yml \
                    --project-directory . up -d"

EOF
