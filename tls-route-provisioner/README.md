# OpenShift TLS Vanity Route Provisioner

Dynamically provisions a secure Vanity Route in OpenShift with cryptographic pre-validation and automated archival backups.

## Why Use This Action?
Instead of carrying a dedicated OpenShift Template for vanity routing in your repository and copy-pasting complex deployment scripts, this composite action natively handles everything.

It provides three massive architectural safety nets:
1. **Cryptographic Validation (Fail-Fast)**: Uses `openssl` to mathematically validate that your private key matches your certificate *before* talking to OpenShift. This physically prevents a garbage secret from taking your live PROD route offline ("dead-in-place").
2. **Automated Archival Backups**: Before overwriting any existing route, it reaches into OpenShift, extracts the live working certificates, and snapshots them into a permanent OpenShift `Secret` (named using a hash of the certificate to prevent secret sprawl). You will never permanently lose a working certificate due to a GitHub Secret overwrite.
3. **No OpenShift Templates Required**: The action dynamically generates the `route.openshift.io/v1` YAML manifest on the fly inside the runner.

## Usage

```yaml
jobs:
  deploy:
    runs-on: ubuntu-24.04
    steps:
      - name: Provision Vanity Route
        if: ${{ inputs.vanity_url != '' }}
        uses: bcgov/actions-openshift/tls-route-provisioner@main
        with:
          vanity_url: ${{ inputs.vanity_url }}
          target_service: "my-app-prod-frontend"
          route_name: "my-app-prod-frontend-vanity"
          tls_certificate: ${{ secrets.TLS_CERTIFICATE }}
          tls_private_key: ${{ secrets.TLS_PRIVATE_KEY }}
          tls_ca_certificate: ${{ secrets.TLS_CA_CERTIFICATE }}
          oc_namespace: ${{ secrets.OC_NAMESPACE }}
          oc_server: ${{ vars.OC_SERVER }}
          oc_token: ${{ secrets.OC_TOKEN }}
```

## Inputs

| Input | Description | Required | Default |
| --- | --- | --- | --- |
| `vanity_url` | The custom vanity URL host (e.g., `myapp.bcgov.ca`) | Yes | |
| `route_name` | The name of the OpenShift route to create | Yes | |
| `target_service` | The name of the OpenShift service to route traffic to | Yes | |
| `tls_certificate` | The public TLS certificate | Yes | |
| `tls_private_key` | The private TLS key | Yes | |
| `tls_ca_certificate` | The CA certificate bundle | No | `""` |
| `oc_namespace` | OpenShift namespace | Yes | |
| `oc_server` | OpenShift server URL | Yes | |
| `oc_token` | OpenShift token | Yes | |
| `dry_run` | If true, skips cluster connection and only validates cryptography and YAML | No | `false` |
