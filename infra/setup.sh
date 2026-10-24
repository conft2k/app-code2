#!/bin/bash
# code2 host: /home on its own volume, code-server behind oauth2-proxy (Cognito).
# Run as root by the user data bootstrap (every boot) and by deploy.sh reconfigure; idempotent. Settings come from
# the stack's SSM parameter /<stack>/setup, so changing them never touches the instance's user data.
set -Eeuo pipefail
exec > >(tee -a /var/log/code2-setup.log) 2>&1
umask 022
# One run at a time: deploy.sh may start one while the boot run is still going; it waits, then runs again.
exec 9>/run/code2-setup.lock
flock 9
stack=${CODE2_STACK:?} region=${AWS_REGION:?} wait_handle=${CODE2_WAIT_HANDLE:-}
log() { echo "code2-setup: $(date -u +%FT%TZ) $*"; }
retry() { local n; for n in 1 2 3 4; do "$@" && return 0; log "retry $n: $1" >&2; sleep $((n * 10)); done; "$@"; }

# First-boot result for BootWait, sent once per instance: CloudFormation ignores later signals and the
# handle's presigned URL expires, so later runs would only log a 403.
signaled=/var/lib/code2-boot-signaled
signal() {
  local body
  [ -n "$wait_handle" ] && [ ! -e $signaled ] || return 0
  body=$(python3 -c 'import json,sys; print(json.dumps({"Status": sys.argv[1], "Reason": sys.argv[2][-900:], "UniqueId": "code2", "Data": sys.argv[2][-900:]}))' "$1" "$2")
  curl -fsS --retry 3 -X PUT -H 'Content-Type:' --data-binary "$body" "$wait_handle" >/dev/null || true
  touch $signaled
}
fail() {
  trap - ERR
  log "FAILED: $1"
  signal FAILURE "$1 | $(tail -n 4 /var/log/code2-setup.log | tr '\n' ' ')"
  exit 1
}
trap 'fail "line $LINENO exited $?"' ERR

# Stack settings (SetupConfig in code2.yaml); only these names are taken from the parameter. A new name needs a
# default here: the stack may still hold an older parameter (reconfigure before apply, or a rolled-back update).
code_server_version='' oauth2_proxy_version='' ttyd_version='' remobi_version=1.2.1 auto_updates='' idle_hours=''
session_hours='' vol='' user_pool='' cognito_host='' log_group=''
settings="code_server_version oauth2_proxy_version ttyd_version remobi_version auto_updates idle_hours session_hours vol user_pool
  cognito_host log_group"
cfg=$(retry aws ssm get-parameter --region "$region" --name "/$stack/setup" --query Parameter.Value --output text)
# shellcheck disable=SC2086
eval "$(python3 -c '
import json, shlex, sys
cfg = json.loads(sys.argv[1])
for k in sys.argv[2:]:
    if k in cfg:
        print(k + "=" + shlex.quote(str(cfg[k])))' "$cfg" $settings)"
for v in $settings; do [ -n "${!v}" ] || fail "/$stack/setup has no $v"; done
vol_serial=${vol/-/}   # nvme serial = volume id without the dash

dl() { curl -fsSL --retry 5 --retry-all-errors --connect-timeout 10 -o "$2" "$1"; }
# put <path> <mode>: writes stdin if it differs; succeeds only when changed.
put() {
  local tmp; tmp=$(mktemp)
  cat > "$tmp"
  if [ -f "$1" ] && cmp -s "$tmp" "$1"; then rm -f "$tmp"; return 1; fi
  install -D -m "$2" "$tmp" "$1"; rm -f "$tmp"
}
# svc <unit> <restart>: enables the unit, restarts it when <restart> is set.
svc() { systemctl daemon-reload; systemctl enable -q "$1"; systemctl "$([ -n "$2" ] && echo restart || echo start)" "$1"; }
case $(uname -m) in
  aarch64) arch=arm64 ;;
  x86_64) arch=amd64 ;;
  *) fail "unsupported architecture $(uname -m)" ;;
esac
work=$(mktemp -d)
log "start (code-server ${code_server_version}, oauth2-proxy ${oauth2_proxy_version}, ttyd ${ttyd_version}, remobi ${remobi_version}, $arch)"

# ---- packages ----
# nodejs22 and gcc-c++ for remobi (node-pty builds with node-gyp)
pkgs="git tmux jq gcc gcc-c++ make tar xfsprogs python3-pip amazon-cloudwatch-agent nodejs22 nodejs22-npm"
if [ "$auto_updates" = true ]; then
  echo latest | put /etc/dnf/vars/releasever 644 || true   # follow new AL2023 releases, not the AMI's
  pkgs="$pkgs dnf-automatic"
fi
# shellcheck disable=SC2086
rpm -q $pkgs >/dev/null 2>&1 || retry dnf install -y -q $pkgs

# ---- /home on the data volume ----
dev=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${vol_serial}
if [ ! -e "$dev" ]; then
  token=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
  iid=$(curl -fsS -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/instance-id)
  # A replacement waits here until the old instance terminates.
  for _ in $(seq 360); do
    state=$(aws ec2 describe-volumes --region "$region" --volume-ids "$vol" \
      --query 'Volumes[0].State' --output text 2>/dev/null || echo unknown)
    if [ "$state" = available ]; then
      aws ec2 attach-volume --region "$region" --volume-id "$vol" --instance-id "$iid" --device /dev/sdf >/dev/null || true
    fi
    [ -e "$dev" ] && break
    sleep 10
  done
  [ -e "$dev" ] || fail "data volume $vol never attached (last state: $state)"
fi
if ! blkid "$dev" >/dev/null 2>&1; then
  log "formatting the new /home volume"
  mkfs.xfs -L code2-home "$dev"
  mount "$dev" /mnt && cp -a /home/. /mnt/ && umount /mnt
fi
grep -q code2-home /etc/fstab || echo 'LABEL=code2-home /home xfs defaults,nofail 0 2' >> /etc/fstab
systemctl daemon-reload
mountpoint -q /home || mount /home
xfs_growfs /home >/dev/null   # picks up a larger DataVolumeSize

# ---- code-server ----
cs=/usr/local/lib/code-server-${code_server_version}
if [ ! -x "$cs/bin/code-server" ]; then
  log "installing code-server ${code_server_version}"
  dl "https://github.com/coder/code-server/releases/download/v${code_server_version}/code-server-${code_server_version}-linux-$arch.tar.gz" "$work/cs.tar.gz"
  rm -rf "$cs" "$work/cs" && mkdir -p "$work/cs"
  tar -xzf "$work/cs.tar.gz" -C "$work/cs" --strip-components 1
  mv "$work/cs" "$cs"
fi
cs_restart=
[ "$(readlink -f /usr/local/bin/code-server)" = "$cs/bin/code-server" ] || cs_restart=1
ln -sfn "$cs/bin/code-server" /usr/local/bin/code-server
put /etc/systemd/system/code-server.service 644 <<'UNIT' && cs_restart=1 || true
[Unit]
Description=code-server (VS Code) for ec2-user
After=network-online.target home.mount
Wants=network-online.target
RequiresMountsFor=/home/ec2-user

[Service]
User=ec2-user
WorkingDirectory=/home/ec2-user
Environment=HOME=/home/ec2-user
ExecStart=/usr/local/bin/code-server --bind-addr 127.0.0.1:8080 --auth none --disable-telemetry --disable-update-check
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
svc code-server "$cs_restart"

# ---- ttyd terminal at /admin/, behind oauth2-proxy ----
td=/usr/local/lib/ttyd-${ttyd_version}
if [ ! -x "$td/ttyd" ]; then
  log "installing ttyd ${ttyd_version}"
  base=https://github.com/tsl0922/ttyd/releases/download/${ttyd_version}
  dl "$base/ttyd.$(uname -m)" "$work/ttyd.$(uname -m)"
  dl "$base/SHA256SUMS" "$work/SHA256SUMS"
  (cd "$work" && sha256sum -c --ignore-missing SHA256SUMS)
  install -D -m 755 "$work/ttyd.$(uname -m)" "$td/ttyd"
fi
td_restart=
[ "$(readlink -f /usr/local/bin/ttyd)" = "$td/ttyd" ] || td_restart=1
ln -sfn "$td/ttyd" /usr/local/bin/ttyd
# Loopback only, like code-server; no -H: ttyd 1.7.7 copies that header into 30 bytes and
# Cognito's sub (36) fails, refusing every WebSocket. KillMode=process keeps tmux on restart.
# No resize overlay: on a phone it covers the screen each time the keyboard opens or closes.
put /etc/systemd/system/ttyd.service 644 <<'UNIT' && td_restart=1 || true
[Unit]
Description=ttyd terminal for ec2-user at /admin/
After=network-online.target home.mount
RequiresMountsFor=/home/ec2-user

[Service]
User=ec2-user
WorkingDirectory=/home/ec2-user
Environment=HOME=/home/ec2-user
ExecStart=/usr/local/bin/ttyd -i lo -p 7681 -b /admin -W -t fontSize=15 -t disableLeaveAlert=true -t disableResizeOverlay=true tmux new -A -s admin
KillMode=process
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
svc ttyd "$td_restart"

# ---- remobi, the phone terminal at /m/, behind oauth2-proxy ----
rd=/usr/local/lib/remobi-${remobi_version}
rcli=$rd/lib/node_modules/remobi/dist/cli.mjs
if [ ! -f "$rcli" ]; then
  log "installing remobi ${remobi_version}"
  rm -rf "$work/remobi"
  # npm checks each package against the registry's integrity hash; dependencies follow remobi's ranges.
  HOME=/root retry npm-22 install -g -q --no-audit --no-fund --omit=dev --prefix "$work/remobi" "remobi@${remobi_version}"
  rm -rf "$rd" && mv "$work/remobi" "$rd"
fi
rm_restart=
[ "$(readlink -f /usr/local/bin/remobi)" = "$rcli" ] || rm_restart=1
ln -sfn "$rd/bin/remobi" /usr/local/bin/remobi
# Same tmux session as ttyd, so either one picks up where the other left off. Loopback only; remobi checks the
# WebSocket Origin against Host, which CloudFront and oauth2-proxy pass through. Config: ~/.config/remobi/.
put /etc/systemd/system/remobi.service 644 <<'UNIT' && rm_restart=1 || true
[Unit]
Description=remobi phone terminal for ec2-user at /m/
After=network-online.target home.mount
RequiresMountsFor=/home/ec2-user

[Service]
User=ec2-user
WorkingDirectory=/home/ec2-user
Environment=HOME=/home/ec2-user
ExecStart=/usr/bin/node-22 /usr/local/bin/remobi serve --host 127.0.0.1 --port 7682 --base-path /m -- tmux new -A -s admin
KillMode=process
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
svc remobi "$rm_restart"

# ---- oauth2-proxy (Cognito OIDC) on :80 ----
opd=/usr/local/lib/oauth2-proxy-v${oauth2_proxy_version}
if [ ! -x "$opd/oauth2-proxy" ]; then
  log "installing oauth2-proxy ${oauth2_proxy_version}"
  op=oauth2-proxy-v${oauth2_proxy_version}.linux-$arch
  base=https://github.com/oauth2-proxy/oauth2-proxy/releases/download/v${oauth2_proxy_version}
  dl "$base/$op.tar.gz" "$work/$op.tar.gz"
  dl "$base/$op.tar.gz-sha256sum.txt" "$work/$op.tar.gz-sha256sum.txt"
  (cd "$work" && sha256sum -c "$op.tar.gz-sha256sum.txt" && tar -xzf "$op.tar.gz")
  install -D -m 755 "$work/$op/oauth2-proxy" "$opd/oauth2-proxy"
fi
op_restart=
[ "$(readlink -f /usr/local/bin/oauth2-proxy)" = "$opd/oauth2-proxy" ] || op_restart=1
ln -sfn "$opd/oauth2-proxy" /usr/local/bin/oauth2-proxy
id oauth2-proxy >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin oauth2-proxy
install -d -m 750 -g oauth2-proxy /etc/oauth2-proxy

# Published once CloudFront is up.
conf=
for _ in $(seq 180); do
  conf=$(aws ssm get-parameter --region "$region" --name /${stack}/oauth2-proxy \
    --query Parameter.Value --output text 2>/dev/null) && break
  sleep 10
done
[ -n "$conf" ] || fail "oauth2-proxy settings never appeared in SSM /${stack}/oauth2-proxy"
client_id=$(jq -r .clientId <<<"$conf")
url=$(jq -r .url <<<"$conf")
put /etc/oauth2-proxy/oauth2-proxy.cfg 644 <<CFG && op_restart=1 || true
http_address = "0.0.0.0:80"
# "/admin/" matches the prefix; "/admin" alone matches only itself and ttyd redirects it to /admin/
upstreams = ["http://127.0.0.1:8080/", "http://127.0.0.1:7681/admin/", "http://127.0.0.1:7681/admin",
  "http://127.0.0.1:7682/m/", "http://127.0.0.1:7682/m"]
provider = "oidc"
provider_display_name = "Cognito"
oidc_issuer_url = "https://cognito-idp.$region.amazonaws.com/${user_pool}"
# Explicit endpoints: discovery may report the old domain while it is replaced.
skip_oidc_discovery = true
login_url = "https://${cognito_host}/oauth2/authorize"
redeem_url = "https://${cognito_host}/oauth2/token"
oidc_jwks_url = "https://cognito-idp.$region.amazonaws.com/${user_pool}/.well-known/jwks.json"
client_id = "$client_id"
redirect_url = "$url/oauth2/callback"
scope = "openid email profile"
code_challenge_method = "S256"
email_domains = ["*"]
whitelist_domains = ["${cognito_host}"]
skip_provider_button = true
cookie_name = "_code2"
cookie_secure = true
cookie_samesite = "lax"
cookie_expire = "${session_hours}h"
cookie_refresh = "30m"
# One CSRF cookie per sign-in, so a background request (service worker, favicon) that starts
# another sign-in cannot replace the PKCE verifier and fail the callback with invalid_grant.
cookie_csrf_per_request = true
cookie_csrf_expire = "15m"
silence_ping_logging = true
CFG
# Secrets stay out of the log; the cookie key is kept across reboots.
secret=$(aws cognito-idp describe-user-pool-client --region "$region" --user-pool-id ${user_pool} \
  --client-id "$client_id" --query UserPoolClient.ClientSecret --output text)
cookie=$(sed -n 's/^OAUTH2_PROXY_COOKIE_SECRET=//p' /etc/oauth2-proxy/secrets.env 2>/dev/null || true)
[ -n "$cookie" ] || cookie=$(python3 -c 'import os,base64;print(base64.urlsafe_b64encode(os.urandom(32)).decode())')
printf 'OAUTH2_PROXY_CLIENT_SECRET=%s\nOAUTH2_PROXY_COOKIE_SECRET=%s\n' "$secret" "$cookie" \
  | put /etc/oauth2-proxy/secrets.env 600 && op_restart=1 || true
put /etc/systemd/system/oauth2-proxy.service 644 <<'UNIT' && op_restart=1 || true
[Unit]
Description=oauth2-proxy (Cognito sign-in in front of code-server, ttyd and remobi)
After=network-online.target
Wants=network-online.target

[Service]
User=oauth2-proxy
Group=oauth2-proxy
EnvironmentFile=/etc/oauth2-proxy/secrets.env
ExecStart=/usr/local/bin/oauth2-proxy --config=/etc/oauth2-proxy/oauth2-proxy.cfg
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
svc oauth2-proxy "$op_restart"

# ---- CloudWatch agent ----
put /opt/aws/amazon-cloudwatch-agent/etc/code2.json 644 <<JSON && cw_restart=1 || cw_restart=
{
  "agent": { "metrics_collection_interval": 300 },
  "metrics": {
    "append_dimensions": { "InstanceId": "\${aws:InstanceId}" },
    "metrics_collected": {
      "disk": { "measurement": ["used_percent"], "resources": ["/", "/home"], "drop_device": true },
      "mem": { "measurement": ["used_percent"] }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/code2-setup.log", "log_group_name": "${log_group}", "log_stream_name": "{instance_id}/setup" },
          { "file_path": "/var/log/code2-idle.log", "log_group_name": "${log_group}", "log_stream_name": "{instance_id}/idle" }
        ]
      }
    }
  }
}
JSON
if [ -n "$cw_restart" ] || ! systemctl is-active -q amazon-cloudwatch-agent; then
  /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/code2.json >/dev/null
fi

# ---- security updates ----
if [ "$auto_updates" = true ]; then
  sed -i -e 's/^upgrade_type *=.*/upgrade_type = security/' -e 's/^apply_updates *=.*/apply_updates = yes/' /etc/dnf/automatic.conf
  systemctl enable --now dnf-automatic.timer
elif systemctl list-unit-files dnf-automatic.timer >/dev/null 2>&1; then
  systemctl disable --now dnf-automatic.timer || true
fi

# ---- idle stop ----
put /usr/local/sbin/code2-idle 755 <<'IDLE' || true
#!/bin/bash
# code2-idle <hours>: stops the instance after <hours> with no viewer, SSH session or load.
stamp=/run/code2-active
if [ ! -f $stamp ] || ss -Htn state established '( sport = :80 or sport = :22 )' | grep -q . \
   || pgrep -u ssm-user >/dev/null || awk '{ exit !($1 > 0.5) }' /proc/loadavg; then
  touch $stamp
fi
idle=$(( $(date +%s) - $(stat -c %Y $stamp) ))
if [ "$idle" -ge $(( $1 * 3600 )) ]; then
  echo "$(date -u +%FT%TZ) idle for $idle s, stopping" >> /var/log/code2-idle.log
  systemctl poweroff
fi
IDLE
if [ "$idle_hours" -gt 0 ]; then
  put /etc/systemd/system/code2-idle.service 644 <<'UNIT' || true
[Unit]
Description=code2 idle stop check
[Service]
Type=oneshot
EnvironmentFile=/etc/code2-idle.env
ExecStart=/usr/local/sbin/code2-idle $HOURS
UNIT
  put /etc/systemd/system/code2-idle.timer 644 <<'UNIT' || true
[Unit]
Description=code2 idle stop check every 5 minutes
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
UNIT
  echo "HOURS=$idle_hours" | put /etc/code2-idle.env 644 || true
  systemctl daemon-reload
  systemctl enable --now code2-idle.timer
elif [ -f /etc/systemd/system/code2-idle.timer ]; then
  systemctl disable --now code2-idle.timer || true
fi

# ---- run the bootstrap again on every boot ----
put /var/lib/cloud/scripts/per-boot/code2-setup 755 <<'HOOK' || true
#!/bin/bash
# Reruns the user data bootstrap, which fetches and runs the current setup.sh, on every boot.
t=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
curl -fsS -H "X-aws-ec2-metadata-token: $t" http://169.254.169.254/latest/user-data > /run/code2-userdata
exec bash /run/code2-userdata
HOOK

rm -rf "$work"
log "done"
signal SUCCESS "code-server ${code_server_version}, oauth2-proxy ${oauth2_proxy_version}, ttyd ${ttyd_version}, remobi ${remobi_version} running"
