#!/usr/bin/env bash
#
# Prepare a fresh DigitalOcean droplet to run the acquisition stack.
#
#   Droplet:  Ubuntu 24.04 LTS, Basic / Regular, 2 GB RAM, 1 vCPU  (~$12/mo)
#   Region:   blr1 — same as the Clinibot droplet. Nothing here is latency
#             sensitive, but keeping both in one region means one `doctl`
#             context and one mental model of where things live.
#
# Run ON the droplet, as root, once:
#   ssh root@<ip> 'bash -s' < ops/provision-droplet.sh
#
# Idempotent: safe to re-run after changing something. Every step checks
# before acting, so a second run reports rather than re-installs.
#
# It deliberately does NOT deploy the app — ops/deploy.sh does that, from
# your laptop. Provisioning is a thing you do once; deploying is a thing you
# do fifty times, and merging them means the risky half runs every time.
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-acq}"
APP_DIR="/opt/acq"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
skip() { printf '    \033[2m(already done: %s)\033[0m\n' "$1"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

# ---------------------------------------------------------------------
step "Swap"
# A 2 GB box running Postgres, n8n and Caddy has no headroom for a spike.
# Without swap the kernel's OOM killer picks a victim, and its favourite
# victim is the largest process — n8n, mid-send. Swap turns a hard kill into
# a slow minute. 2 GB, matching RAM.
if swapon --show | grep -q '/swapfile'; then
  skip "swapfile active"
else
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  # Prefer RAM but do not refuse swap outright; the default 60 is too eager
  # for a database host and 0 defeats the point of having it.
  sysctl -qw vm.swappiness=10
  grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
  echo "    2 GB swapfile created"
fi

# ---------------------------------------------------------------------
step "Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg postgresql-client \
                       ufw fail2ban unattended-upgrades >/dev/null
echo "    base packages present (incl. psql, for ops/deploy.sh)"

# ---------------------------------------------------------------------
step "Docker"
if command -v docker >/dev/null 2>&1; then
  skip "docker $(docker --version | awk '{print $3}' | tr -d ,)"
else
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
                         docker-buildx-plugin docker-compose-plugin >/dev/null
  systemctl enable --now docker
  echo "    docker installed"
fi

# Container logs are the other way a small droplet fills its disk. Uncapped
# json-file logging is unbounded by default; n8n is chatty.
if [ ! -f /etc/docker/daemon.json ]; then
  cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON
  systemctl restart docker
  echo "    docker log rotation capped at 30 MB/container"
else
  skip "/etc/docker/daemon.json exists"
fi

# ---------------------------------------------------------------------
step "Deploy user"
if id "$DEPLOY_USER" >/dev/null 2>&1; then
  skip "user $DEPLOY_USER"
else
  adduser --disabled-password --gecos "" "$DEPLOY_USER" >/dev/null
  usermod -aG docker "$DEPLOY_USER"
  # Carry root's authorized_keys over, so the key that ran this script can
  # still get in as the unprivileged user afterwards. Forgetting this is how
  # you provision a box you can only reach as root.
  if [ -f /root/.ssh/authorized_keys ]; then
    install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
    install -m 600 -o "$DEPLOY_USER" -g "$DEPLOY_USER" \
      /root/.ssh/authorized_keys "/home/$DEPLOY_USER/.ssh/authorized_keys"
  fi
  echo "    created $DEPLOY_USER (docker group, root's SSH keys copied)"
fi

install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$APP_DIR"

# ---------------------------------------------------------------------
step "Firewall"
# Only three ports. Postgres (5433) and the n8n UI (5679) are bound to
# 127.0.0.1 by compose and are reached through an SSH tunnel — they are
# deliberately absent here, and adding them would defeat that.
if ufw status | grep -q 'Status: active'; then
  skip "ufw active"
else
  ufw --force reset >/dev/null
  ufw default deny incoming  >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp  comment 'ssh'   >/dev/null
  ufw allow 80/tcp  comment 'http — ACME challenge only' >/dev/null
  ufw allow 443/tcp comment 'https — /webhook/* only'    >/dev/null
  ufw --force enable >/dev/null
  echo "    ufw: 22, 80, 443 in; everything else denied"
fi

systemctl enable --now fail2ban >/dev/null 2>&1 || true

# ---------------------------------------------------------------------
step "Unattended security upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
echo "    security updates apply automatically"

# ---------------------------------------------------------------------
step "Outbound SMTP reachability"
# DigitalOcean blocks outbound port 25 on new accounts, and will often not
# open it. This does NOT matter here — mail goes out through Zoho on 587 with
# authentication, not by direct-to-MX delivery on 25. Checked anyway, because
# discovering it while debugging a silent send failure costs an evening.
if timeout 5 bash -c 'cat < /dev/null > /dev/tcp/smtp.zoho.com/587' 2>/dev/null; then
  echo "    port 587 to smtp.zoho.com: reachable"
else
  echo "    WARNING: cannot reach smtp.zoho.com:587 — outbound mail will fail."
  echo "             Check the droplet's firewall and DigitalOcean account limits."
fi

# ---------------------------------------------------------------------
step "Done"
cat <<EOF

  Droplet is ready. It is running nothing yet.

  $(free -m | awk '/^Mem:/ {printf "RAM  %s MB total, %s MB used", $2, $3}')
  $(df -h / | awk 'NR==2 {printf "Disk %s of %s used", $3, $2}')

  Next, from your laptop:

    1. Point DNS at this droplet:
         A   <the subdomain in N8N_HOST>   $(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || echo '<this droplet IP>')
       Wait for it to resolve before deploying — Caddy asks Let's Encrypt for
       a certificate on first start, and a failed challenge counts against a
       rate limit that is measured in hours.

    2. Add to ~/.ssh/config:
         Host acq
           HostName $(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || echo '<this droplet IP>')
           User $DEPLOY_USER

    3. ./ops/deploy.sh

EOF
