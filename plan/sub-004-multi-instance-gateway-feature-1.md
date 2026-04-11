---
goal: Gateway per-instance HTTPS listeners, HTTPRoutes, and TLS certificates
plan_type: sub
parent_plan: parent-multi-instance-aks-feature-1.md#SUB-004
version: 1.0
date_created: 2026-04-11
last_updated: 2026-04-11
status: 'Planned'
tags: [kubernetes, gateway, dns, tls, networking]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

Update the shared Kubernetes Gateway and create per-instance HTTPRoute resources to route HTTPS traffic to each OpenClaw instance at its unique DNS hostname. Each instance gets one HTTPS Gateway listener, one TLS certificate (issued by cert-manager via Let's Encrypt HTTP-01), and one HTTPRoute in its own namespace. The HTTP listener (port 80) remains shared for ACME HTTP-01 challenges and HTTP→HTTPS redirects.

**Dev hostnames:** `ch-paa-dev.acmeadventure.ca`, `jh-paa-dev.acmeadventure.ca`  
**Prod hostnames:** `ch-paa.acmeadventure.ca`, `jh-paa.acmeadventure.ca`, `kjm-paa.acmeadventure.ca`

## 1. Requirements & Constraints

- **REQ-001**: Each instance has exactly one dedicated HTTPS Gateway listener: `https-{inst}-dev` (dev) or `https-{inst}-prod` (prod).
- **REQ-002**: Listener hostname: `{inst}-paa-dev.acmeadventure.ca` (dev) or `{inst}-paa.acmeadventure.ca` (prod).
- **REQ-003**: TLS certificate secret name: `{inst}-paa-dev-tls` (dev) or `{inst}-paa-tls` (prod), stored in `gateway-system` namespace.
- **REQ-004**: cert-manager issues certificates automatically via the `cert-manager.io/cluster-issuer` annotation on the Gateway resource.
- **REQ-005**: HTTPRoute for each instance lives in `openclaw-{inst}` namespace; routes all paths (`/`) to service `openclaw` port 18789.
- **REQ-006**: HTTP→HTTPS redirect HTTPRoute for each hostname must be added (port 80 listener).
- **REQ-007**: All legacy single-instance listeners (`https-dev`, `https-prod`) and their corresponding HTTPRoutes must be removed after per-instance routes are confirmed healthy.
- **SEC-001**: TLS must terminate at the Gateway; no pass-through. Traffic inside the cluster is plain HTTP.
- **CON-001**: `letsencrypt-staging` ClusterIssuer is used during initial validation; switch to `letsencrypt-prod` only after staging certs are confirmed `READY`.
- **CON-002**: All new hostnames resolve to the same Gateway LoadBalancer IP as the existing hostnames — operator must create DNS A records before certs can be issued.

## 2. Implementation Steps

### Implementation Phase 1 — Update Gateway with Per-Instance Listeners

- GOAL-001: Replace legacy `https-dev` and `https-prod` listeners with per-instance listeners in `workloads/bootstrap/gateway.yaml`.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-001 | In `workloads/bootstrap/gateway.yaml`: remove the legacy `https-dev` listener (hostname `paa-dev.acmeadventure.ca`) and `https-prod` listener (hostname `paa.acmeadventure.ca`). | | |
| TASK-002 | Add per-instance HTTPS listeners for dev — `https-ch-dev` (hostname `ch-paa-dev.acmeadventure.ca`, cert secret `ch-paa-dev-tls`) and `https-jh-dev` (hostname `jh-paa-dev.acmeadventure.ca`, cert secret `jh-paa-dev-tls`). Each listener: `protocol: HTTPS`, `port: 443`, `allowedRoutes.namespaces.from: All`, `tls.mode: Terminate`. | | |
| TASK-003 | Add per-instance HTTPS listeners for prod — `https-ch-prod`, `https-jh-prod`, `https-kjm-prod` with hostnames `ch-paa.acmeadventure.ca`, `jh-paa.acmeadventure.ca`, `kjm-paa.acmeadventure.ca` and cert secrets `ch-paa-tls`, `jh-paa-tls`, `kjm-paa-tls`. | | |
| TASK-004 | Retain the `http` listener (port 80, `allowedRoutes.namespaces.from: All`) — it handles HTTP-01 ACME challenges and HTTP→HTTPS redirects for all hostnames. | | |
| TASK-005 | Ensure the Gateway annotation `cert-manager.io/cluster-issuer: letsencrypt-staging` remains on the resource so cert-manager automatically issues certificates for all HTTPS listeners. | | |

### Implementation Phase 2 — Per-Instance HTTPRoutes

- GOAL-002: Create per-instance HTTPRoute manifests in each instance's bootstrap directory.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-006 | For each instance `{inst}` in dev (`ch`, `jh`), create `workloads/dev/openclaw-{inst}/bootstrap/httproute.yaml` containing two resources: (1) HTTP→HTTPS redirect route attaching to `sectionName: http` for hostname `{inst}-paa-dev.acmeadventure.ca`; (2) HTTPS route attaching to `sectionName: https-{inst}-dev` for hostname `{inst}-paa-dev.acmeadventure.ca`, forwarding all paths to service `openclaw` port 18789. | | |
| TASK-007 | For each instance `{inst}` in prod (`ch`, `jh`, `kjm`), create `workloads/prod/openclaw-{inst}/bootstrap/httproute.yaml` with the same structure but using `https-{inst}-prod` and `{inst}-paa.acmeadventure.ca`. | | |
| TASK-008 | Remove legacy `workloads/dev/openclaw/bootstrap/httproute.yaml` and `workloads/prod/openclaw/bootstrap/httproute.yaml` after per-instance routes are validated. | | |

### Implementation Phase 3 — DNS Records

- GOAL-003: Create DNS A records for all new instance hostnames pointing to the Gateway LoadBalancer IP.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-009 | Retrieve the current Gateway LoadBalancer IP: `kubectl get svc -n gateway-system`. Note the `EXTERNAL-IP` of the NGINX Gateway Fabric service. | | |
| TASK-010 | In the DNS provider for `acmeadventure.ca`, create A records: `ch-paa-dev`, `jh-paa-dev` (dev); `ch-paa`, `jh-paa`, `kjm-paa` (prod) — all pointing to the same LoadBalancer IP as the existing `paa-dev` and `paa` records. | | |
| TASK-011 | Verify DNS propagation using `dig {inst}-paa-dev.acmeadventure.ca` from the dev environment; confirm the IP matches the Gateway LoadBalancer IP. | | |

### Implementation Phase 4 — Certificate Verification

- GOAL-004: Confirm cert-manager issues and marks certificates READY for all instance hostnames.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-012 | After applying the updated `gateway.yaml` and ensuring DNS records are propagated, run `kubectl get certificates -n gateway-system` to monitor cert-manager certificate issuance for each instance secret name. | | |
| TASK-013 | For each instance, confirm the Certificate resource for `{inst}-paa-dev-tls` / `{inst}-paa-tls` reaches `READY=True` status. If a certificate fails, check cert-manager logs and HTTP-01 challenge pod status in the `openclaw-{inst}` namespace. | | |
| TASK-014 | Once all staging certificates are READY, update the Gateway annotation to `letsencrypt-prod` and re-apply: `kubectl annotate gateway main-gateway -n gateway-system cert-manager.io/cluster-issuer=letsencrypt-prod --overwrite`. Certificates will be re-issued with trusted CA. | | |

## 3. Alternatives

- **ALT-001**: Wildcard listener `*.paa-dev.acmeadventure.ca` with a wildcard TLS certificate — requires DNS-01 ACME challenge and an external DNS provider integration. Rejected: adds provider dependency; HTTP-01 per hostname is already proven in this cluster.
- **ALT-002**: One Gateway per instance — maximum isolation but multiplies LoadBalancer IP cost and Gateway Fabric instances. Rejected: a single shared Gateway with per-instance listeners achieves the required routing isolation at lower cost.

## 4. Dependencies

- **DEP-001**: SUB-003 (Terraform) must complete before this subplan applies changes to the cluster — cert-manager ClusterIssuers must exist.
- **DEP-002**: DNS delegation for `acmeadventure.ca` sub-records must be under operator control (already confirmed for existing `paa-dev` / `paa` records).
- **DEP-003**: NGINX Gateway Fabric must support multiple HTTPS listeners with distinct hostnames on the same port (confirmed: this is standard Gateway API behavior).

## 5. Files

- **FILE-001**: [workloads/bootstrap/gateway.yaml](../workloads/bootstrap/gateway.yaml) — replace legacy listeners with per-instance listeners
- **FILE-002**: `workloads/dev/openclaw-ch/bootstrap/httproute.yaml` — instance ch dev HTTPRoutes (new)
- **FILE-003**: `workloads/dev/openclaw-jh/bootstrap/httproute.yaml` — instance jh dev HTTPRoutes (new)
- **FILE-004**: `workloads/prod/openclaw-ch/bootstrap/httproute.yaml` — instance ch prod HTTPRoutes (new)
- **FILE-005**: `workloads/prod/openclaw-jh/bootstrap/httproute.yaml` — instance jh prod HTTPRoutes (new)
- **FILE-006**: `workloads/prod/openclaw-kjm/bootstrap/httproute.yaml` — instance kjm prod HTTPRoutes (new)
- **FILE-007**: `workloads/dev/openclaw/bootstrap/httproute.yaml` — remove after validation
- **FILE-008**: `workloads/prod/openclaw/bootstrap/httproute.yaml` — remove after validation

## 6. Testing

- **TEST-001**: `kubectl get gateway main-gateway -n gateway-system -o yaml` — confirm all expected listeners are present with correct hostnames.
- **TEST-002**: `kubectl get httproutes -A` — confirm per-instance HTTPRoutes exist in `openclaw-{inst}` namespaces and no orphaned legacy routes remain.
- **TEST-003**: `kubectl get certificates -n gateway-system` — all instance TLS secrets reach `READY=True`.
- **TEST-004**: `curl -v https://ch-paa-dev.acmeadventure.ca` from an approved IP — confirm 200 or 401 (gateway token required) and valid TLS cert CN.

## 7. Risks & Assumptions

- **RISK-001**: Let's Encrypt rate limits — issuing 5 certificates during dev+prod validation may approach the staging rate limit. Use `letsencrypt-staging` for all initial issuance; switch to `letsencrypt-prod` only after staging succeeds cleanly.
- **RISK-002**: Removing legacy listeners before per-instance routes are confirmed healthy will cause a brief unavailability of the existing single-instance deployment. Sequence: add new listeners first → validate new routes → then remove legacy routes and listeners.
- **ASSUMPTION-001**: The existing `paa-dev.acmeadventure.ca` and `paa.acmeadventure.ca` DNS records and Gateway listeners can remain temporarily alongside the new per-instance listeners during the migration window.

## 8. Related Specifications / Further Reading

- [plan/feature-multi-instance-aks-1.md](../plan/feature-multi-instance-aks-1.md)
- [workloads/bootstrap/gateway.yaml](../workloads/bootstrap/gateway.yaml)
- [workloads/dev/openclaw/bootstrap/httproute.yaml](../workloads/dev/openclaw/bootstrap/httproute.yaml)
- [ARCHITECTURE.md — Azure Runtime Platform section](../ARCHITECTURE.md)
