# ADR 0001: Per-repository certificate management in `cert-keeper`

## Status

Accepted

## Context

OpenShift Routes serving custom vanity hostnames require valid TLS certificates. As public certificate lifetimes shrink (Let's Encrypt moving from 90 days to 64 and 45 days, alongside industry 47-day caps), manual Service Desk renewals do not scale. Centralizing renewals into a single shared workflow or embedding certificate issuance inside application deployment pipelines would either widen the blast radius of OpenShift credentials across namespaces or couple site availability to unrelated code deployments.

## Decision

1. `cert-keeper` is opt-in and runs per repository in its own standalone workflow—never inside `merge.yml`, `release.yml`, or continuous deployment pipelines. Let's Encrypt mode uses a daily `schedule` (plus `workflow_dispatch`), whereas pre-supplied certificate mode (`tls_certificate`, `tls_private_key`, `tls_ca_certificate`) uses on-demand `workflow_dispatch`.
2. Each consuming repository provides its own namespace-scoped OpenShift token and configuration (`oc_token`, `oc_namespace`, `oc_server`, `hostname`, `route_name`, `target_service`), limiting access strictly to that repository's namespace without cluster-admin privileges or DNS API credentials.
3. In Let's Encrypt mode, `cert-keeper` checks the TLS certificate currently served by the hostname on each run and exits without changes unless the host lacks its own valid certificate, the certificate has expired, one-third or less of its lifetime remains, or `force: true` is passed.
4. For Let's Encrypt HTTP-01 validation, `cert-keeper` creates ephemeral `app.kubernetes.io/managed-by=cert-keeper` objects (`Pod`, `Service`, `NetworkPolicy`, and a `/.well-known/acme-challenge` `Route`) and removes them on both success and failure. When pre-supplied certificates are provided, `cert-keeper` bypasses the expiry check and Let's Encrypt issuance and runs the Route install step directly.
5. Independent expiry monitoring and alerting remain separate from renewal (for example, `bcgov/nr-cert-monitor`).

## Consequences

- Credentials, failures, and OpenShift Route changes stay isolated to each repository's own namespace and `prod` environment.
- Owning teams control their own schedule, `route_name`, and failure notifications.
- Wildcard certificates, DNS-01 challenges, and multi-host Let's Encrypt certificates remain out of scope (handled by dedicated cluster tooling such as `bcgov/cert-manager-proxy`).
