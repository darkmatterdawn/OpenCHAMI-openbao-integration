# Description
A script to set up an OpenBao vault to be used in an existing OpenCHAMI installation.
This procedure was developed for, and has been tested in, quadlet-based OpenCHAMI setups using recent openchami-release versions up until 0.1.9.
It has not been tested yet with release 0.2.0.

The setup mirrors what the OpenCHAMI quadlet setup in the openchami-release does, as in, the main container relies on an init-container.
However: To avoid maintaining a clone of the OpenBao container within the OpenCHAMI universe, the upstream OpenBao container is used with an entrypoint script mounted from the host.
For the same reason, there is no openbao-init container, but rater an openbao-init service which follows the same design principle.

Overall, this procedure makes the minimal amount of necessary changes to the existing OpenCHAMI setup and tries to keep things simple, similar and without too many dependencies, making maintenance and debugging easier.

# How to set up openbao vault
```
sudo ./openbao-setup.sh 2>&1 | tee openbao-setup.log
```
Use `-f` to force the script execution without interactive user confirmation.

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
# requires ochami cli to be configured and auth token exported in a variable
# with the expected name

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
