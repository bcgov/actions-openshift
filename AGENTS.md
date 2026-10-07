# AGENTS.md

Repository facts and constraints for automated coding assistants.

## Action Architecture & Rules

- **`route-tls` is standalone only**: When assisting downstream repositories with custom vanity Route TLS, always implement it as an independent on-demand workflow (`.github/workflows/route-tls.yml` on `workflow_dispatch` with `dry_run` choice defaulting to `true`). **NEVER** embed `route-tls` into `merge.yml`, `release.yml`, or continuous deployment pipelines.
- **Secret Management**: Certificates belong in the `prod` GitHub Environment (`TLS_CERTIFICATE`, `TLS_PRIVATE_KEY`, `TLS_CA_CERTIFICATE`). Automated assistants must never manage secrets directly; draft copy-pasteable `gh secret set` commands in chat for human maintainers.
- **Entrust Certificate Mapping**:
  - `TLS_CERTIFICATE`: leaf only (`<host>.pem`).
  - `TLS_PRIVATE_KEY`: unencrypted private key (`<host>.key`).
  - `TLS_CA_CERTIFICATE`: issuing intermediate only (`Entrust OV TLS Issuing RSA CA 2.pem`). Exclude root CAs and `.csr`.
- **Bash over JavaScript**: Actions in this repository stay in bash (`openssl` + `oc`). Do not rewrite composite actions to Node.js or JavaScript.
- **Pinning**: Pin third-party actions to full 40-character commit SHAs with `# vX.Y.Z` trailing comments. Never pin `@main`.
