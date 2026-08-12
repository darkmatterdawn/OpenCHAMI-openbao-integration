#!/bin/bash
# Apply OpenBao-related modifications to a clean OpenCHAMI installation.
# Existing files are backed up once to *.openbao-orig-backup and then modified
# with sed so the original content is preserved and new items are appended.
set -e

backup_once() {
    local file="$1"
    local backup="${file}.openbao-orig-backup"
    if [ ! -f "$backup" ]; then
        sudo cp "$file" "$backup"
        echo "[apply] Backed up $file -> $backup"
    fi
}

echo "[apply] Creating new OpenBao files..."
sudo mkdir -p /etc/openchami/scripts

cat << 'EOF' | sudo tee /etc/containers/systemd/openbao-certs.volume > /dev/null
[Unit]
Description=OpenBao TLS certificates volume

[Volume]
VolumeName=openbao-certs
EOF

if [ ! -f /etc/containers/systemd/openbao-data.volume ]; then
cat << 'EOF' | sudo tee /etc/containers/systemd/openbao-data.volume > /dev/null
[Unit]
Description=OpenBao data volume

[Volume]
VolumeName=openbao-data
EOF
fi

cat << 'EOF' | sudo tee /etc/containers/systemd/openbao.container > /dev/null
[Unit]
Description=The openbao container
PartOf=openchami.target

[Container]
ContainerName=openbao
HostName=openbao
Image=quay.io/openbao/openbao:2.2.0

# Volumes
Volume=openbao-data.volume:/openbao/data
Volume=/etc/openchami/configs/openbao.hcl:/etc/openchami/configs/openbao.hcl:Z
Volume=/etc/openchami/configs/openbao-entrypoint.sh:/openbao-entrypoint.sh:Z
Volume=/etc/openchami/configs/openbao-smd-creds-policy.hcl:/etc/openchami/configs/openbao-smd-creds-policy.hcl:ro,Z
Volume=openbao-certs.volume:/openbao/certs:Z

# Secrets
Secret=openbao_unseal_key,type=mount,target=openbao_unseal_key
Secret=openbao_root_token,type=mount,target=openbao_root_token

# Environment Variables
Environment=BAO_ADDR=https://127.0.0.1:8200
Environment=BAO_CACERT=/openbao/certs/ca.crt

# Command to run in container
Exec=/openbao-entrypoint.sh

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

cat << 'EOF' | sudo tee /etc/openchami/configs/openbao.hcl > /dev/null
# - File backend on podman volume for data persistence
# - TLS listener using step-ca issued certificate
# - UI disabled

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

cat << 'EOF' | sudo tee /etc/openchami/configs/openbao-entrypoint.sh > /dev/null
#!/bin/sh
set -e

CONFIG_FILE=/etc/openchami/configs/openbao.hcl
UNSEAL_KEY_FILE=/run/secrets/openbao_unseal_key
ROOT_TOKEN_FILE=/run/secrets/openbao_root_token

export BAO_ADDR=https://127.0.0.1:8200
export BAO_CACERT=/openbao/certs/ca.crt
export BAO_SKIP_VERIFY=true

until [ -f /openbao/certs/tls.fullchain ] && [ -f /openbao/certs/tls.key ] && [ -f /openbao/certs/ca.crt ]; do
    echo "Waiting for TLS certificates..."
    sleep 2
done

if [ ! -r "$UNSEAL_KEY_FILE" ] || [ ! -r "$ROOT_TOKEN_FILE" ]; then
    echo "ERROR: OpenBao unseal key and/or root token secrets are missing." >&2
    exit 1
fi

UNSEAL_KEY=$(cat "$UNSEAL_KEY_FILE")
ROOT_TOKEN=$(cat "$ROOT_TOKEN_FILE")

echo "Starting OpenBao server..."
bao server -config="$CONFIG_FILE" &
BAO_PID=$!

cleanup() {
    kill "$BAO_PID" 2>/dev/null || true
}
trap cleanup TERM INT

until bao status >/dev/null 2>&1 || [ $? -eq 2 ]; do
    sleep 1
done

if ! bao status 2>/dev/null | grep -q "Initialized.*true"; then
    echo "ERROR: OpenBao is not initialized." >&2
    exit 1
fi

echo "Unsealing OpenBao..."
bao operator unseal "$UNSEAL_KEY"

export BAO_TOKEN="$ROOT_TOKEN"

if ! bao secrets list 2>/dev/null | grep -q '^secret/'; then
    echo "Enabling KV v1 secrets engine at secret/..."
    bao secrets enable -path=secret kv
fi

wait "$BAO_PID"
EOF
sudo chmod +x /etc/openchami/configs/openbao-entrypoint.sh

cat << 'EOF' | sudo tee /etc/openchami/scripts/smd-wrapper.sh > /dev/null
#!/bin/sh
echo "namespace" > /tmp/cray-vault-namespace
echo "token"     > /tmp/cray-vault-token

export CRAY_VAULT_ROLE_FILE=/tmp/cray-vault-namespace
export CRAY_VAULT_JWT_FILE=/tmp/cray-vault-token

exec /smd "$@"
EOF
sudo chmod +x /etc/openchami/scripts/smd-wrapper.sh

cat << 'EOF' | sudo tee /etc/openchami/configs/openbao-smd-creds-policy.hcl > /dev/null
path "secret/hms-creds/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "auth/token/create" {
  capabilities = ["create", "update"]
}
EOF

cat << 'EOF' | sudo tee /etc/systemd/system/openbao-cert-renewal.service > /dev/null
[Unit]
Description=Renew OpenBao certificate and restart dependent services

[Service]
Type=oneshot
TimeoutStartSec=300
ExecStart=/etc/openchami/scripts/openbao-cert-renewal.sh
StandardOutput=journal
EOF

cat << 'EOF' | sudo tee /etc/systemd/system/openbao-cert-renewal.timer > /dev/null
[Unit]
Description=Renew OpenBao certificate twice daily

[Timer]
OnBootSec=5m
OnUnitActiveSec=12h
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat << 'EOF' | sudo tee /etc/openchami/scripts/openbao-cert-renewal.sh > /dev/null
#!/bin/bash
set -e

ACME_IMAGE=docker.io/neilpang/acme.sh:3.1.1
CA_BUNDLE=/root_ca/root_ca.crt
ACME_SERVER=https://step-ca:9000/acme/acme/directory
CERT_VOLUME=openbao-certs

echo "[openbao-cert-renewal] Issuing certificate for openbao..."
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
  --standalone \
  --force

echo "[openbao-cert-renewal] Installing certificate into ${CERT_VOLUME} Podman volume..."
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

echo "[openbao-cert-renewal] Restarting openbao if it is active..."
systemctl try-restart openbao

echo "[openbao-cert-renewal] Done."
EOF
sudo chmod +x /etc/openchami/scripts/openbao-cert-renewal.sh

echo "[apply] Backing up and modifying existing OpenCHAMI files..."
backup_once /etc/containers/systemd/smd.container
backup_once /etc/containers/systemd/step-ca.container
backup_once /etc/openchami/configs/openchami.env
backup_once /etc/systemd/system/openchami.target

# smd.container: add OpenBao dependency, secret, volumes, and wrapper Exec
# Use Wants= (not Requires=) so that restarting openbao for certificate
# renewal does not tear down smd.
if ! grep -qE 'Requires=openbao.service|Wants=openbao.service' /etc/containers/systemd/smd.container; then
    sudo sed -i '/After=hydra-gen-jwks.service/a # Don'\''t start until OpenBao is ready:\nWants=openbao.service\nAfter=openbao.service' /etc/containers/systemd/smd.container
fi

if ! grep -q 'Secret=openbao_token' /etc/containers/systemd/smd.container; then
    sudo sed -i '/Secret=smd_postgres_password,type=env,target=SMD_DBPASS/a Secret=openbao_token,type=env,target=VAULT_TOKEN' /etc/containers/systemd/smd.container
fi

if ! grep -q 'Exec=/etc/openchami/scripts/smd-wrapper.sh' /etc/containers/systemd/smd.container; then
    sudo sed -i '/# Networks for the Container to use/i # Volumes\nVolume=/etc/openchami/configs/:/etc/openchami/configs:Z\nVolume=/etc/openchami/scripts/smd-wrapper.sh:/etc/openchami/scripts/smd-wrapper.sh:ro,Z\nVolume=openbao-certs.volume:/etc/openchami/certs/openbao:ro,Z\n\n# Command to run in container\nExec=/etc/openchami/scripts/smd-wrapper.sh\n' /etc/containers/systemd/smd.container
fi

# step-ca.container: add provisioner-password secret
if ! grep -q 'Secret=stepca_provisioner_password' /etc/containers/systemd/step-ca.container; then
    sudo sed -i '/EnvironmentFile=\/etc\/openchami\/configs\/openchami.env/a # Secrets\nSecret=stepca_provisioner_password,type=env,target=DOCKER_STEPCA_INIT_PROVISIONER_PASSWORD' /etc/containers/systemd/step-ca.container
fi

# openchami.env: move provisioner password to secret and add OpenBao/Vault settings
if grep -q '^DOCKER_STEPCA_INIT_PROVISIONER_PASSWORD=' /etc/openchami/configs/openchami.env; then
    sudo sed -i 's/^DOCKER_STEPCA_INIT_PROVISIONER_PASSWORD=.*/# DOCKER_STEPCA_INIT_PROVISIONER_PASSWORD is now supplied via the\n# stepca_provisioner_password Podman secret./' /etc/openchami/configs/openchami.env
fi

if ! grep -q 'VAULT_ADDR=https://openbao:8200' /etc/openchami/configs/openchami.env; then
    cat << 'EOF' | sudo tee -a /etc/openchami/configs/openchami.env > /dev/null

# OpenBao/Vault settings for SMD credential storage
VAULT_ADDR=https://openbao:8200
VAULT_KEYPATH=secret/hms-creds
VAULT_CACERT=/etc/openchami/certs/openbao/ca.crt
CRAY_VAULT_AUTH_PATH=auth/token/create
# CRAY_VAULT_ROLE_FILE and CRAY_VAULT_JWT_FILE are set by
# /etc/openchami/scripts/smd-wrapper.sh using temporary files in /tmp.
SMD_WVAULT=true
SMD_RVAULT=true
EOF
fi

# openchami.target: add openbao.service to Wants and After.
# Keep it out of Requires= so that restarting openbao for certificate
# renewal does not deactivate the whole target.
if grep -q '^Requires=.*openbao.service' /etc/systemd/system/openchami.target; then
    sudo sed -i 's/^\(Requires=.*\) openbao.service/\1/' /etc/systemd/system/openchami.target
fi
if ! grep -q '^Wants=.*openbao.service' /etc/systemd/system/openchami.target; then
    sudo sed -i '/^Wants=/ s/$/ openbao.service/' /etc/systemd/system/openchami.target
fi
if ! grep -q '^After=.*openbao.service' /etc/systemd/system/openchami.target; then
    sudo sed -i '/^After=/ s/$/ openbao.service/' /etc/systemd/system/openchami.target
fi

echo "[apply] Reloading systemd..."
sudo systemctl daemon-reload

echo "[apply] Done."
