#!/bin/bash
# Append OpenBao secret-management functions to /usr/libexec/openchami/bootstrap_openchami.sh
# and call them at the end of that script.
set -e

BOOTSTRAP=/usr/libexec/openchami/bootstrap_openchami.sh
BACKUP="${BOOTSTRAP}.openbao-orig-backup"

if [ ! -f "$BOOTSTRAP" ]; then
    echo "ERROR: $BOOTSTRAP not found." >&2
    exit 1
fi

if grep -q 'setup_openbao' "$BOOTSTRAP"; then
    echo "[extend] bootstrap_openchami.sh already contains OpenBao functions; skipping."
    exit 0
fi

if [ ! -f "$BACKUP" ]; then
    sudo cp "$BOOTSTRAP" "$BACKUP"
    echo "[extend] Backed up $BOOTSTRAP -> $BACKUP"
fi

cat << 'EOF' | sudo tee -a "$BOOTSTRAP" > /dev/null

# ---------------------------------------------------------------------------
# OpenBao secret setup (idempotent)
# ---------------------------------------------------------------------------

create_stepca_provisioner_password_secret() {
    local pass=""
    local backup="/etc/openchami/configs/openchami.env.openbao-orig-backup"

    # Try the live env first (for pre-modification runs), then the backup.
    pass=$(grep -m1 '^DOCKER_STEPCA_INIT_PROVISIONER_PASSWORD=' /etc/openchami/configs/openchami.env 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
    if [ -z "$pass" ] && [ -f "$backup" ]; then
        pass=$(grep -m1 '^DOCKER_STEPCA_INIT_PROVISIONER_PASSWORD=' "$backup" | cut -d= -f2- | tr -d '"' || true)
    fi

    if [ -z "$pass" ]; then
        echo "[bootstrap] WARNING: Could not find DOCKER_STEPCA_INIT_PROVISIONER_PASSWORD in openchami.env or its backup." >&2
        echo "[bootstrap] Please create the stepca_provisioner_password Podman secret manually." >&2
        return 1
    fi

    create_secret_if_not_exists "stepca_provisioner_password" "$pass"
}

setup_openbao() {
    local image="quay.io/openbao/openbao:2.2.0"
    local config="/etc/openchami/configs/openbao.hcl"
    local certs="openbao-certs"
    local data="openbao-data"

    # The OpenBao service needs a certificate before we can initialize it.
    if [ ! -f "/var/lib/containers/storage/volumes/${certs}/_data/tls.fullchain" ]; then
        echo "[bootstrap] OpenBao certificate not yet available; skipping OpenBao secret setup."
        echo "[bootstrap] Run bootstrap_openchami.sh again after the OpenBao certificate has been issued."
        return 0
    fi

    # Initialize OpenBao if the unseal/root-token secrets are missing.
    if ! podman secret inspect openbao_unseal_key &>/dev/null || ! podman secret inspect openbao_root_token &>/dev/null; then
        echo "[bootstrap] Initializing OpenBao..."
        local tmpdir
        tmpdir=$(mktemp -d)

        podman run --rm \
            --name openbao-init \
            -v "${data}:/openbao/data" \
            -v "${config}:/etc/openchami/configs/openbao.hcl:Z" \
            -v "${certs}:/openbao/certs:Z" \
            -v "${tmpdir}:/init-out:Z" \
            -e BAO_ADDR=https://127.0.0.1:8200 \
            -e BAO_CACERT=/openbao/certs/ca.crt \
            -e BAO_SKIP_VERIFY=true \
            "${image}" \
            sh -c '
                set -e
                bao server -config=/etc/openchami/configs/openbao.hcl &
                BAO_PID=$!
                until bao status >/dev/null 2>&1 || [ $? -eq 2 ]; do sleep 1; done
                if bao status 2>/dev/null | grep -q "Initialized.*true"; then
                    echo "already-initialized" > /init-out/status
                else
                    bao operator init -key-shares=1 -key-threshold=1 > /init-out/init.json
                fi
                kill "$BAO_PID" 2>/dev/null || true
            '

        if [ -f "${tmpdir}/status" ]; then
            echo "[bootstrap] OpenBao is already initialized, but the unseal/root-token secrets are missing." >&2
            echo "[bootstrap] Restore the secrets or delete the openbao-data volume and re-run." >&2
            rm -rf "$tmpdir"
            return 1
        fi

        local unseal_key root_token
        unseal_key=$(awk '/Unseal Key 1:/{print $NF}' "${tmpdir}/init.json")
        root_token=$(awk '/Initial Root Token:/{print $NF}' "${tmpdir}/init.json")

        create_secret_if_not_exists "openbao_unseal_key" "$unseal_key"
        create_secret_if_not_exists "openbao_root_token" "$root_token"
        rm -rf "$tmpdir"
    fi

    # Create the long-lived SMD token if it does not exist yet.
    if ! podman secret inspect openbao_token &>/dev/null; then
        echo "[bootstrap] Creating SMD token in OpenBao..."
        local tmpdir
        tmpdir=$(mktemp -d)

        local unseal_key root_token
        unseal_key=$(podman secret inspect openbao_unseal_key --showsecret | jq -r '.[0].SecretData')
        root_token=$(podman secret inspect openbao_root_token --showsecret | jq -r '.[0].SecretData')

        podman run --rm \
            --name openbao-token-init \
            -v "${data}:/openbao/data" \
            -v "${config}:/etc/openchami/configs/openbao.hcl:Z" \
            -v "${certs}:/openbao/certs:Z" \
            -v "${tmpdir}:/token-out:Z" \
            -v "/etc/openchami/configs/openbao-smd-creds-policy.hcl:/policy.hcl:ro,Z" \
            -e BAO_ADDR=https://127.0.0.1:8200 \
            -e BAO_CACERT=/openbao/certs/ca.crt \
            -e BAO_SKIP_VERIFY=true \
            -e UNSEAL_KEY="$unseal_key" \
            -e ROOT_TOKEN="$root_token" \
            "${image}" \
            sh -c '
                set -e
                bao server -config=/etc/openchami/configs/openbao.hcl &
                BAO_PID=$!
                until bao status >/dev/null 2>&1 || [ $? -eq 2 ]; do sleep 1; done
                bao operator unseal "$UNSEAL_KEY"
                export BAO_TOKEN="$ROOT_TOKEN"
                bao policy write smd-creds /policy.hcl
                bao token create -policy=smd-creds -display-name=smd -ttl=768h -format=json > /token-out/smd-token.json
                kill "$BAO_PID" 2>/dev/null || true
            '

        local smd_token
        smd_token=$(jq -r '.auth.client_token' "${tmpdir}/smd-token.json")
        create_secret_if_not_exists "openbao_token" "$smd_token"
        rm -rf "$tmpdir"
    fi

    echo "[bootstrap] OpenBao secrets are present."
}

# Create the step-ca provisioner password secret (replaces the plaintext env var).
create_stepca_provisioner_password_secret

# Run OpenBao setup; if certificates are not ready yet this call is a no-op
# and can simply be repeated later.
setup_openbao
EOF

echo "[extend] Extended $BOOTSTRAP with OpenBao setup."
