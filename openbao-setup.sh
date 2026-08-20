#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT

set -euo pipefail

# sanity checks
## must be root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (or with sudo)." >&2
    exit 1
fi

## check if OpenCAMI is installed
if [ ! -d /etc/openchami ]; then
    echo "ERROR: Could not find existing OpenCHAMI installation."
    exit 1
fi

## check if acme-register.container exists
if [ ! -f /etc/containers/systemd/acme-register.container ]
then
  echo "ERROR: File /etc/containers/systemd/acme-register.container does not exist."
  exit 1
fi

## check if openbao was already set up
if [ -d /etc/openchami/openbao ]; then
    echo "ERROR: OpenBao appears to be set up already. Cowardly refusing to continue, since this may break the existing installation."
    exit 1
fi


# preparations
BACKUP_FILENAME_EXTENSION="openbao.bak.$(date +%Y%m%d%H%M)"
OPENBAO_IMAGE="quay.io/openbao/openbao:2.2.0"

mkdir -p /etc/openchami/openbao
mkdir -p /etc/openchami/smd


# write openbao config
tee /etc/openchami/openbao/openbao.hcl > /dev/null << 'EOF'
storage "file" {
  path = "/openbao/data"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/openbao/certs/tls.fullchain"
  tls_key_file  = "/openbao/certs/tls.key"
}

api_addr = "https://openbao:8200"

ui = false
EOF


# write entrypoint script for openbao container
tee /etc/openchami/openbao/openbao-entrypoint.sh > /dev/null << 'EOF'
#!/bin/sh
set -e

CONFIG_FILE=/etc/openchami/openbao/openbao.hcl
UNSEAL_KEY_FILE=/run/secrets/openbao_unseal_key
ROOT_TOKEN_FILE=/run/secrets/openbao_root_token

export BAO_ADDR=https://127.0.0.1:8200
export BAO_CACERT=/openbao/certs/ca.crt
export BAO_SKIP_VERIFY=true

until [ -f /openbao/certs/tls.fullchain ] && [ -f /openbao/certs/tls.key ] && [ -f /openbao/certs/ca.crt ]; do
    sleep 2
done

if [ ! -r "$UNSEAL_KEY_FILE" ] || [ ! -r "$ROOT_TOKEN_FILE" ]; then
    echo "ERROR: OpenBao unseal key and/or root token secrets are missing." >&2
    exit 1
fi

UNSEAL_KEY=$(cat "$UNSEAL_KEY_FILE")
ROOT_TOKEN=$(cat "$ROOT_TOKEN_FILE")

bao server -config="$CONFIG_FILE" &
BAO_PID=$!

cleanup() {
    kill "$BAO_PID" 2>/dev/null || true
}
trap cleanup TERM INT

while true; do
    rc=0
    bao status >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then
        break
    fi
    sleep 1
done

if ! bao status 2>/dev/null | grep -q "Initialized.*true"; then
    echo "ERROR: OpenBao is not initialized." >&2
    exit 1
fi

bao operator unseal "$UNSEAL_KEY"

export BAO_TOKEN="$ROOT_TOKEN"

if ! bao secrets list 2>/dev/null | grep -q '^secret/'; then
    bao secrets enable -path=secret kv
fi

wait "$BAO_PID"
EOF

chmod +x /etc/openchami/openbao/openbao-entrypoint.sh


# write openbao credentials policy for SMD token
tee /etc/openchami/openbao/openbao-smd-creds-policy.hcl > /dev/null << 'EOF'
path "secret/hms-creds/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "auth/token/create" {
  capabilities = ["create", "update"]
}
EOF


# write openbao-init script execxuted by openbao-init.service
tee /etc/openchami/openbao/openbao-init.sh > /dev/null << 'EOF'
#!/bin/bash
# Idempotent OpenBao initialization.
# Creates only the core podman secrets: openbao_unseal_key and openbao_root_token.
# Exits cleanly if those secrets already exist.
set -euo pipefail

IMAGE=$(grep '^Image=' /etc/containers/systemd/openbao.container | cut -d '=' -f2)
if [ -z "$IMAGE" ]; then
    echo "[openbao-init] ERROR: Could not determine OpenBao image from openbao.container" >&2
    exit 1
fi
CONFIG="/etc/openchami/openbao/openbao.hcl"
DATA_VOL="openbao-data"
CERTS_VOL="openbao-certs"

# Resolve the actual host mountpoint of the named volume
CERT_MOUNT=$(podman volume inspect --format '{{.Mountpoint}}' "$CERTS_VOL" 2>/dev/null) || {
    echo "[openbao-init] ERROR: Podman volume ${CERTS_VOL} does not exist." >&2
    exit 1
}

TMPDIR1=""

cleanup() {
    [ -n "$TMPDIR1" ] && rm -rf "$TMPDIR1"
}
trap cleanup EXIT

# --- Idempotency: skip everything if the core secrets are already present ---
if podman secret inspect openbao_unseal_key &>/dev/null && \
   podman secret inspect openbao_root_token &>/dev/null; then
    exit 0
fi

# --- The certificate must exist before OpenBao can initialize ---
if [ ! -f "${CERT_MOUNT}/tls.fullchain" ]; then
    echo "[openbao-init] ERROR: OpenBao TLS certificate not found at ${CERT_MOUNT}/tls.fullchain" >&2
    echo "[openbao-init] Issue the certificate first, e.g.:" >&2
    echo "    sudo /etc/openchami/openbao/openbao-cert-renewal.sh" >&2
    exit 1
fi

# --- Initialize OpenBao in a temporary container ---
TMPDIR1=$(mktemp -d)

podman run --rm \
    --name openbao-init \
    -v "${DATA_VOL}:/openbao/data" \
    -v "${CONFIG}:/etc/openchami/openbao/openbao.hcl:Z" \
    -v "${CERTS_VOL}:/openbao/certs:Z" \
    -v "${TMPDIR1}:/init-out:Z" \
    -e BAO_ADDR=https://127.0.0.1:8200 \
    -e BAO_CACERT=/openbao/certs/ca.crt \
    -e BAO_SKIP_VERIFY=true \
    "${IMAGE}" \
    sh -c '
        set -e
        bao server -config=/etc/openchami/openbao/openbao.hcl &
        BAO_PID=$!
        until bao status >/dev/null 2>&1 || [ $? -eq 2 ]; do sleep 1; done
        if bao status 2>/dev/null | grep -q "Initialized.*true"; then
            echo "already-initialized" > /init-out/status
        else
            bao operator init -key-shares=1 -key-threshold=1 > /init-out/init.json
        fi
        kill "$BAO_PID" 2>/dev/null || true
    '

if [ -f "${TMPDIR1}/status" ]; then
    echo "[openbao-init] ERROR: OpenBao is already initialized, but the unseal/root-token secrets are missing." >&2
    echo "[openbao-init] Restore the openbao_unseal_key and openbao_root_token Podman secrets from backup." >&2
    echo "[openbao-init] If no backup exists, the OpenBao data is unrecoverable; delete the openbao-data volume and re-initialize as a last resort." >&2
    exit 1
fi

unseal_key=$(awk '/Unseal Key 1:/{print $NF}' "${TMPDIR1}/init.json")
root_token=$(awk '/Initial Root Token:/{print $NF}' "${TMPDIR1}/init.json")

printf '%s' "$unseal_key" | podman secret create openbao_unseal_key -
printf '%s' "$root_token" | podman secret create openbao_root_token -
EOF

chmod +x /etc/openchami/openbao/openbao-init.sh


# write openbao-init service file
tee /etc/systemd/system/openbao-init.service > /dev/null << 'EOF'
[Unit]
Description=Initialize OpenBao secrets
PartOf=openchami.target
StartLimitIntervalSec=60
StartLimitBurst=3
After=network.target openbao-cert-renewal.service

[Service]
Type=oneshot
ExecStart=/etc/openchami/openbao/openbao-init.sh
RemainAfterExit=yes
Restart=no
EOF


# write script to renew SMD token / podman secret for openbao
tee /etc/openchami/openbao/openbao-smd-token-renewal.sh > /dev/null << 'EOF'
#!/bin/bash
# Idempotent SMD OpenBao token creation/renewal.
# Creates or recreates the 'smd_openbao_token' Podman secret when the existing
# token is missing or within 7 days of expiry, then restarts smd.service.
set -euo pipefail

TOKEN_NAME="smd_openbao_token"
MIN_TTL=604800  # 7 days

# --- Prerequisites ---
if ! podman secret inspect openbao_root_token &>/dev/null; then
    echo "[token-renewal] ERROR: openbao_root_token secret not found." >&2
    exit 1
fi

if ! systemctl is-active --quiet openbao.service; then
    echo "[token-renewal] ERROR: openbao.service is not running." >&2
    exit 1
fi

# --- Wait for the OpenBao container to be reachable via podman exec ---
# The service may report "active" before the container is ready to accept exec.
max_attempts=5
attempt=1
while [ "$attempt" -le "$max_attempts" ]; do
    if podman exec openbao true >/dev/null 2>&1; then
        break
    fi
    # OpenBao container not yet accessible, wait for a bit
    sleep 2
    attempt=$((attempt + 1))
done

if [ "$attempt" -gt "$max_attempts" ]; then
    echo "[token-renewal] ERROR: OpenBao container is not accessible via podman exec after ${max_attempts} attempts." >&2
    exit 1
fi

# --- Wait for OpenBao to become unsealed ---
max_unseal_attempts=30
unseal_attempt=1
while [ "$unseal_attempt" -le "$max_unseal_attempts" ]; do
    if podman exec -e BAO_SKIP_VERIFY=true openbao bao status >/dev/null 2>&1; then
        break
    fi
    echo "[token-renewal] OpenBao is still sealed (attempt $unseal_attempt/$max_unseal_attempts), retrying in 1s..." >&2
    sleep 1
    unseal_attempt=$((unseal_attempt + 1))
done

if [ "$unseal_attempt" -gt "$max_unseal_attempts" ]; then
    echo "[token-renewal] ERROR: OpenBao did not become unsealed after ${max_unseal_attempts} attempts." >&2
    exit 1
fi

root_token=$(podman secret inspect openbao_root_token --showsecret | jq -r '.[0].SecretData')

bao_exec_root() {
    podman exec -e BAO_SKIP_VERIFY=true -e BAO_TOKEN="$root_token" openbao "$@"
}

# --- Check existing token ---
if podman secret inspect "$TOKEN_NAME" &>/dev/null; then
    existing_token=$(podman secret inspect "$TOKEN_NAME" --showsecret | jq -r '.[0].SecretData')

    if ttl=$(podman exec -e BAO_SKIP_VERIFY=true -e BAO_TOKEN="$existing_token" openbao bao token lookup -format=json 2>/dev/null | jq -r '.data.ttl // 0'); then
        if [[ "$ttl" =~ ^[0-9]+$ ]] && [ "$ttl" -gt "$MIN_TTL" ]; then
            exit 0
        fi
    fi
fi

# --- Ensure SMD policy exists ---
bao_exec_root bao policy write smd-creds /etc/openchami/openbao/openbao-smd-creds-policy.hcl

# --- Create new SMD token ---
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

bao_exec_root bao token create -policy=smd-creds -display-name=smd -ttl=768h -format=json > "${tmpdir}/smd-token.json"

smd_token=$(jq -r '.auth.client_token' "${tmpdir}/smd-token.json")

# --- Update secret ---
if podman secret inspect "$TOKEN_NAME" &>/dev/null; then
    podman secret rm "$TOKEN_NAME"
fi

printf '%s' "$smd_token" | podman secret create "$TOKEN_NAME" -

# --- Restart SMD so it picks up the new secret ---
systemctl try-restart smd.service
EOF

chmod +x /etc/openchami/openbao/openbao-smd-token-renewal.sh


# write service file and respective timer to renew SMD token / podman secret for openbao
tee /etc/systemd/system/openbao-smd-token-renewal.service > /dev/null << 'EOF'
[Unit]
Description=Renew SMD OpenBao token
PartOf=openchami.target
StartLimitIntervalSec=60
StartLimitBurst=3
Requires=openbao.service
After=openbao.service

[Service]
Type=oneshot
ExecStart=/etc/openchami/openbao/openbao-smd-token-renewal.sh
RemainAfterExit=yes
Restart=on-failure
RestartSec=10
EOF


tee /etc/systemd/system/openbao-smd-token-renewal.timer > /dev/null << 'EOF'
[Unit]
Description=Renew SMD OpenBao token daily

[Timer]
OnBootSec=5m
OnUnitActiveSec=24h
Persistent=true

[Install]
WantedBy=timers.target
EOF


# write openbao container and volumes quadlet definitions
tee /etc/containers/systemd/openbao.container > /dev/null << EOF
[Unit]
Description=The openbao container
PartOf=openchami.target
Requires=openbao-init.service
After=openbao-init.service

[Container]
ContainerName=openbao
HostName=openbao
Image=${OPENBAO_IMAGE}

# Volumes
Volume=openbao-data:/openbao/data
Volume=/etc/openchami/openbao/openbao.hcl:/etc/openchami/openbao/openbao.hcl:Z
Volume=/etc/openchami/openbao/openbao-entrypoint.sh:/etc/openchami/openbao/openbao-entrypoint.sh:Z
Volume=/etc/openchami/openbao/openbao-smd-creds-policy.hcl:/etc/openchami/openbao/openbao-smd-creds-policy.hcl:ro,Z
Volume=openbao-certs:/openbao/certs:Z

# Secrets
Secret=openbao_unseal_key,type=mount,target=openbao_unseal_key
Secret=openbao_root_token,type=mount,target=openbao_root_token

# Environment Variables
Environment=BAO_ADDR=https://127.0.0.1:8200
Environment=BAO_CACERT=/openbao/certs/ca.crt

# Command to run in container
Exec=/etc/openchami/openbao/openbao-entrypoint.sh

# Capabilities
AddCapability=IPC_LOCK

# Networks
Network=openchami-internal.network

# Unsupported by generator options
PodmanArgs=--http-proxy=false

[Service]
Restart=always
RestartSec=5
EOF


tee /etc/containers/systemd/openbao-certs.volume > /dev/null << 'EOF'
[Unit]
Description=OpenBao TLS certificates volume

[Volume]
VolumeName=openbao-certs
EOF


tee /etc/containers/systemd/openbao-data.volume > /dev/null << 'EOF'
[Unit]
Description=OpenBao data volume

[Volume]
VolumeName=openbao-data
EOF


# SMD's hms-securestorage library expects Kubernetes service-account files
# (role and JWT) even when using token auth. OpenCHAMI is not running under
# Kubernetes in this setup, so provide static placeholder files are used
echo "openchami" > /etc/openchami/smd/cray-vault-role
echo "token-auth-placeholder" > /etc/openchami/smd/cray-vault-jwt
chmod 644 /etc/openchami/smd/cray-vault-role /etc/openchami/smd/cray-vault-jwt


# backup and modify smd.container
cp /etc/containers/systemd/smd.container /etc/containers/systemd/smd.container.$BACKUP_FILENAME_EXTENSION

## add dependencies introduced by openbao
## use Wants instead of Requires, so a restart of openbao (e.g. for cert renewal) does not force an SMD restart
sed -i '/After=smd-init.service/a\
\
# Do not start until OpenBao is ready:\
Wants=openbao.service openbao-smd-token-renewal.service\
After=openbao.service openbao-smd-token-renewal.service' /etc/containers/systemd/smd.container

## add podman secret for SMD's openbao token
sed -i '/target=SMD_DBPASS/a Secret=smd_openbao_token,type=env,target=VAULT_TOKEN' /etc/containers/systemd/smd.container

## add volumes
sed -i '/# Networks for the Container to use/i\
# Volumes\
Volume=/etc/openchami/configs/:/etc/openchami/configs:Z\
Volume=/etc/openchami/smd/cray-vault-role:/etc/openchami/smd/cray-vault-role:ro,Z\
Volume=/etc/openchami/smd/cray-vault-jwt:/etc/openchami/smd/cray-vault-jwt:ro,Z\
Volume=openbao-certs:/etc/openchami/certs/openbao:ro,Z\
' /etc/containers/systemd/smd.container

## add cray-vault placeholder environment variables
sed -i '/EnvironmentFile=/a\
# CRAY_VAULT_ROLE_FILE and CRAY_VAULT_JWT_FILE point to static placeholder\
# files because SMD expects Kubernetes-style auth files.\
Environment=CRAY_VAULT_ROLE_FILE=/etc/openchami/smd/cray-vault-role\
Environment=CRAY_VAULT_JWT_FILE=/etc/openchami/smd/cray-vault-jwt' /etc/containers/systemd/smd.container


# set up TLS cert renewal for OpenBao from step-ca
tee /etc/openchami/openbao/openbao-cert-renewal.sh > /dev/null << 'EOF'
#!/bin/bash
set -e

ACME_IMAGE=$(grep '^Image=' /etc/containers/systemd/acme-register.container | cut -d '=' -f2)
if [ -z "$ACME_IMAGE" ]; then
    echo "[openbao-cert-renewal] ERROR: Could not determine ACME image from acme-register.container" >&2
    exit 1
fi

CA_BUNDLE=/root_ca/root_ca.crt
ACME_SERVER=https://step-ca:9000/acme/acme/directory
CERT_VOLUME=openbao-certs

# Resolve the actual host mountpoint of the named volume (works for rootless,
# custom graphroot, and different storage drivers).
CERT_MOUNT=$(podman volume inspect --format '{{.Mountpoint}}' "$CERT_VOLUME" 2>/dev/null) || {
    echo "[openbao-cert-renewal] ERROR: Podman volume ${CERT_VOLUME} does not exist." >&2
    exit 1
}
CERT_FILE="${CERT_MOUNT}/tls.crt"
RENEW_THRESHOLD=43200   # 12 hours in seconds

needs_renewal() {
    if [ ! -f "$CERT_FILE" ]; then
        return 0
    fi
    expiry=$(date -d "$(openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d= -f2)" +%s)
    now=$(date +%s)
    [ $((expiry - now)) -le "$RENEW_THRESHOLD" ]
}

if ! needs_renewal; then
    # Certificate still valid for more than 12h; skipping renewal
    exit 0
fi

podman run --rm \
  --hostname openbao \
  --network openchami-cert-internal \
  -v /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem:"${CA_BUNDLE}":ro,Z \
  -v acme-certs:/acme.sh:z \
  --env-file /etc/openchami/configs/openchami.env \
  "${ACME_IMAGE}" \
  --issue \
  --ca-bundle "${CA_BUNDLE}" \
  --server "${ACME_SERVER}" \
  --home /acme.sh \
  -d openbao \
  --standalone

podman run --rm \
  --network openchami-cert-internal \
  -v /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem:"${CA_BUNDLE}":ro,Z \
  -v acme-certs:/acme.sh:Z \
  -v "${CERT_VOLUME}:/openbao-certs:Z" \
  --env-file /etc/openchami/configs/openchami.env \
  "${ACME_IMAGE}" \
  --install-cert \
  --ca-bundle "${CA_BUNDLE}" \
  --server "${ACME_SERVER}" \
  -d openbao \
  --home /acme.sh \
  --cert-file /openbao-certs/tls.crt \
  --key-file /openbao-certs/tls.key \
  --ca-file /openbao-certs/ca.crt \
  --fullchain-file /openbao-certs/tls.fullchain

systemctl try-restart openbao
EOF

chmod +x /etc/openchami/openbao/openbao-cert-renewal.sh


tee /etc/systemd/system/openbao-cert-renewal.service > /dev/null << 'EOF'
[Unit]
Description=Renew OpenBao certificate and restart the service
Requires=step-ca.service
After=step-ca.service

[Service]
Type=oneshot
TimeoutStartSec=300
RemainAfterExit=yes
ExecStartPre=/bin/sh -c 'until /usr/bin/podman exec step-ca step ca health --ca-url https://step-ca:9000 --root /root_ca/root_ca.crt >/dev/null 2>&1; do sleep 2; done'
ExecStart=/etc/openchami/openbao/openbao-cert-renewal.sh
StandardOutput=journal
EOF


tee /etc/systemd/system/openbao-cert-renewal.timer > /dev/null << 'EOF'
[Unit]
Description=Renew OpenBao certificate twice daily

[Timer]
OnBootSec=5m
OnUnitActiveSec=1d
Persistent=true

[Install]
WantedBy=timers.target
EOF


# add new, necessary environment variables to openchami.env
cp /etc/openchami/configs/openchami.env /etc/openchami/configs/openchami.env.$BACKUP_FILENAME_EXTENSION

sed -i '/^SMD_JWKS_URL=/a\
\
# OpenBao/Vault settings for SMD credential storage\
SMD_WVAULT=true\
SMD_RVAULT=true\
VAULT_ADDR=https://openbao:8200\
VAULT_KEYPATH=secret/hms-creds\
VAULT_CACERT=/etc/openchami/certs/openbao/ca.crt\
CRAY_VAULT_AUTH_PATH=auth/token/create' /etc/openchami/configs/openchami.env


# add OpenBao to openchami.target
cp /etc/systemd/system/openchami.target /etc/systemd/system/openchami.target.$BACKUP_FILENAME_EXTENSION

sed -i '/^Wants=/ s/$/ openbao.service/' /etc/systemd/system/openchami.target
sed -i '/^After=/ s/$/ openbao.service/' /etc/systemd/system/openchami.target



# apply the changes and run steps for initial openbao setup
systemctl daemon-reload
systemctl stop openchami.target

## at the time of initial setup, no container has used the openbao-* volumes yet,
## so they have to be created manually
systemctl start openbao-certs-volume.service
systemctl start openbao-data-volume.service

systemctl start openbao-cert-renewal.service
systemctl enable --quiet --now openbao-cert-renewal.timer

systemctl start openbao-smd-token-renewal.service
systemctl enable --quiet --now openbao-smd-token-renewal.timer

systemctl start openchami.target
