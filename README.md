# Description
First working draft of integrating openbao vault into an existing OpenCHAMI setup.
The existing setup was created by following the steps in the tutorial.

# Notes
The place where certain things happen, and their order, are still somewhat sketchy. (Kimi 2.7 Code has the right spirit, but it needs a little more guidance / manual clean-up work).
However, it does work, and I publish the first draft in that state already so folks can start working on their own setups.

# How to set up openbao vault
As mentioned, this requires a pre-existing OpenCHAMI installation. Then, follow these steps:

```
# 1. Extend bootstrap (only needed once per host)
sudo ./01-extend-bootstrap-openbao.sh

# 2. Apply all OpenBao file modifications
sudo ./02-apply-openbao-modifications.sh

# 3. If the target is already running on this host, stop it first so the
#    modified services are recreated cleanly.
sudo systemctl stop openchami.target

# 4. First bootstrap pass: creates postgres/step-ca secrets, env vars, etc.
#    OpenBao setup is skipped because the certificate does not exist yet.
sudo /usr/libexec/openchami/bootstrap_openchami.sh

# 5. Start step-ca so the ACME provisioner is reachable
sudo systemctl start step-ca.service

# 6. Issue the first OpenBao certificate
sudo /etc/openchami/scripts/openbao-cert-renewal.sh

# 7. Second bootstrap pass: now creates openbao_unseal_key,
#    openbao_root_token and openbao_token secrets.
sudo /usr/libexec/openchami/bootstrap_openchami.sh

# 8. Start the full stack
sudo systemctl start openchami.target

# 9. Enable automatic certificate renewal
sudo systemctl enable --now openbao-cert-renewal.timer
```

# Verification
## Services
sudo systemctl is-active openchami.target openbao.service smd.service haproxy.service step-ca.service

## OpenBao status
```
ROOT=$(sudo podman secret inspect openbao_root_token --showsecret | jq -r '.[0].SecretData')
sudo podman exec -e BAO_SKIP_VERIFY=true -e BAO_TOKEN=$ROOT openbao bao status
```

## Test SMD credential storage
### Create components in SMD
Example:
```
cat <<'EOF' > x5000c0s0b0-rfe.yaml
RedfishEndpoints:
  - id: x5000c0s0b0
    type: NodeBMC
    name: x5000c0s0b0 BMC
    hostname: x5000c0s0b0
    domain: openchami.cluster
    enabled: true
    user: root
    password: secret-password
    macaddr: "05:00:00:00:00:00"
    ipaddress: 10.100.0.50
    rediscoveronupdate: false
EOF

ochami smd rfe add -d @x5000c0s0b0-rfe.yaml -f yaml


cat <<'EOF' > x5000-components.yaml
Components:
  - ID: x5000c0s0b0
    Type: NodeBMC
    Enabled: true
    State: Ready
  - ID: x5000c0s0b0n0
    Type: Node
    NID: 22
    Role: Compute
    Arch: X86
    Enabled: true
    State: Ready
EOF

ochami smd component add -d @x5000-components.yaml -f yaml


cat <<'EOF' > x5000-ifaces.yaml
- ID: x5000c0s0b0n0-eth0
  ComponentID: x5000c0s0b0n0
  Type: EthernetInterface
  Description: Node management interface
  MACAddress: "05:00:00:00:00:01"
  IPAddresses:
    - Network: NMN
      IPAddress: 10.100.1.50
EOF

ochami smd iface add -d @x5000-ifaces.yaml -f yaml
```

### After that, SMD should return Password="" and the real password should be in OpenBao:
```
ROOT=$(sudo podman secret inspect openbao_root_token --showsecret | jq -r '.[0].SecretData')
sudo podman exec -e BAO_SKIP_VERIFY=true -e BAO_TOKEN=$ROOT openbao bao kv get secret/hms-creds/x5000c0s0b0

ochami smd rfe get -x x5000c0s0b0 -F yaml
```
