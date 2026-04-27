---
goal: Proxy all public-facing ingress through Cloudflare free tier; restrict NGINX LoadBalancer to Cloudflare IPs; remove direct `public_ip` restriction
plan_type: standalone
version: "1.0"
date_created: 2026-04-20
owner: Craig Holmes
status: 'Planned'
tags: [feature, security, infrastructure, ingress, cloudflare]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

Route all public HTTPS traffic for `acmeadventure.ca` through Cloudflare's free-tier proxy and WAF before it reaches the NGINX Gateway Fabric LoadBalancer on AKS. Once Cloudflare is confirmed to be the only path to the origin, restrict the Azure LoadBalancer to accept traffic from Cloudflare IP ranges only, eliminating direct public exposure of the LB IP. Finally, remove the now-redundant `public_ip` Terraform variable and `PUBLIC_IP` GitHub secret.

**Traffic flow after this change:**

```
User → Cloudflare edge (TLS termination, WAF, DDoS) → Cloudflare → originating IP = Cloudflare range → Azure LB NSG allow → NGINX Gateway Fabric → HTTPRoute → OpenClaw pod
```

## 1. Requirements & Constraints

- **REQ-001**: All public HTTPS hostnames under `acmeadventure.ca` must be proxied through Cloudflare (orange-cloud DNS records) before the LoadBalancer restriction is applied. Applying the restriction before Cloudflare is active causes an outage.
- **REQ-002**: Both environments (dev and prod) must be migrated. Dev and prod share the same `acmeadventure.ca` DNS zone, so a single Cloudflare zone covers both.
- **REQ-003**: cert-manager HTTP-01 ACME challenges must continue to work after Cloudflare is in place. HTTP-01 works through Cloudflare proxy as long as "Always Use HTTPS" is **not** enabled in Cloudflare — the NGINX gateway handles HTTP→HTTPS redirects for regular traffic.
- **REQ-004**: Cloudflare SSL/TLS mode must be set to **Full**: Cloudflare terminates TLS at the edge and re-connects to origin over HTTPS using the Let's Encrypt cert. Do NOT use Flexible (sends plain HTTP to origin). Note: Full (Strict) requires a Cloudflare Origin CA cert at origin; Universal SSL does not qualify for Strict mode.
- **REQ-005**: After the LoadBalancer restriction is in place, direct access to the LB IP from a non-Cloudflare IP must be blocked at the Azure NSG level.
- **REQ-006**: The `public_ip` Terraform variable and `PUBLIC_IP` GitHub secret must not be removed until the Cloudflare restriction is confirmed active in both environments.
- **SEC-001**: Do not expose the Azure LoadBalancer IP in public DNS — point all DNS records to Cloudflare. Once proxied, `dig` on hostnames returns Cloudflare anycast IPs, not the LB IP.
- **SEC-002**: Do not enable Cloudflare "Always Use HTTPS" — this redirects `/.well-known/acme-challenge/` requests before they reach the origin and breaks HTTP-01 cert renewal.
- **SEC-003**: Never store the Cloudflare API token or Zone ID in source code. If DNS-01 challenges are adopted (Phase 5), the Cloudflare API token must be stored as a Kubernetes Secret seeded via Key Vault.
- **CON-001**: Cloudflare free tier. No Cloudflare Tunnel (Argo), no Load Balancing, no custom WAF rules beyond managed rulesets. Cloudflare Authenticated Origin Pulls are available on free but require NGINX client-cert config — deferred to Phase 5.
- **CON-002**: `loadBalancerSourceRanges` on the NGINX Gateway Fabric Kubernetes Service translates to Azure NSG inbound rules on the AKS node resource group. AKS reconciles NSG rules each time the service is updated.
- **CON-003**: Cloudflare IP ranges change occasionally. The values file `workloads/bootstrap/ngf-values.yaml` must be updated when Cloudflare publishes range changes. The canonical source is https://www.cloudflare.com/ips-v4 and https://www.cloudflare.com/ips-v6.
- **GUD-001**: Apply `loadBalancerSourceRanges` during a low-traffic window. AKS reconciles the NSG rule nearly instantly, but there is a brief transition period where existing connections may be dropped.
- **GUD-002**: Test with dev environment first; validate before applying prod.
- **PAT-001**: Cloudflare configuration is manual (Cloudflare dashboard or Terraform Cloudflare provider). This plan uses the dashboard for initial setup. Terraform Cloudflare provider adoption is noted as a future improvement.

## 2. Implementation Steps

> **Status as of 2026-04-27:** Phases 1 and 2 are complete. Phase 3 (PR #47 merged) and Phase 5 code changes (PR #48 open) are done. HSTS is out of scope — treat as a future enhancement. Remaining: TASK-016/017 (validate dev LB restriction), TASK-019 (prod promotion), TASK-024 (Blob Storage tfvars), TASK-025 (delete PUBLIC_IP GitHub secret), TASK-026 (terraform plan validation).

### Phase 1 — Cloudflare Account & Zone Setup (Manual — Cloudflare Dashboard)

- GOAL-001: Create Cloudflare free-tier account and add the `acmeadventure.ca` zone. Configure SSL/TLS and WAF baseline before any DNS changes.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-001 | Log in to https://dash.cloudflare.com, add site `acmeadventure.ca`, select the **Free** plan. | ✓ | 2026-04-26 |
| TASK-002 | Record the two Cloudflare-assigned nameservers. These replaced the registrar NS records in Phase 2. | ✓ | 2026-04-26 |
| TASK-003 | In Cloudflare **SSL/TLS → Overview**: set encryption mode to **Full**. Do NOT use Flexible. Note: Full (Strict) requires a Cloudflare Origin CA cert — Universal SSL does not qualify. | ✓ | 2026-04-26 |
| TASK-004 | In Cloudflare **SSL/TLS → Edge Certificates**: confirm Universal SSL is Active. Do NOT enable "Always Use HTTPS" — leave it off to preserve HTTP-01 ACME challenge flows. HSTS is out of scope for this plan. | ✓ | 2026-04-27 |
| TASK-005 | In Cloudflare **Security → WAF**: confirm the Cloudflare Free Managed Ruleset is active. | ✓ | 2026-04-26 |
| TASK-006 | In Cloudflare **Security → Bots**: enable **Bot Fight Mode** (free tier). | ✓ | 2026-04-26 |
| TASK-007 | Create the following A records in Cloudflare DNS, set to **Proxied** (orange cloud). Hostnames use hyphens (not dots) to stay within the one-level subdomain covered by Cloudflare Universal SSL. Remove old dot-notation records if any exist.<br><br>`ch-paa-dev.acmeadventure.ca → 52.191.18.153`<br>`jh-paa-dev.acmeadventure.ca → 52.191.18.153`<br>`ch-paa.acmeadventure.ca → 172.171.181.166`<br>`jh-paa.acmeadventure.ca → 172.171.181.166`<br>`kjm-paa.acmeadventure.ca → 172.171.181.166` | ✓ | 2026-04-27 |

### Phase 2 — Nameserver Delegation & DNS Cutover (Manual — Registrar + Cloudflare Dashboard)

- GOAL-002: Delegate `acmeadventure.ca` DNS to Cloudflare and confirm proxied records are serving traffic. Do NOT apply `loadBalancerSourceRanges` until this phase is confirmed working.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-008 | At the `acmeadventure.ca` domain registrar, update nameservers to the two Cloudflare NS values from TASK-002. | ✓ | 2026-04-26 |
| TASK-009 | Confirm Cloudflare dashboard **Overview** shows "Active". Verify `dig acmeadventure.ca NS` returns Cloudflare nameservers. | ✓ | 2026-04-26 |
| TASK-010 | Confirm all A records from TASK-007 are Proxied. `dig ch-paa-dev.acmeadventure.ca` should return Cloudflare anycast IPs, not the Azure LB IP. | ✓ | 2026-04-26 |
| TASK-011 | Verify cert-manager renewals: `kubectl get certificate -A` — all certs must show `READY=True`. If a cert is near expiry, trigger manual renewal: `kubectl -n openclaw-ch delete secret ch-paa-dev-tls`. Confirms HTTP-01 works through Cloudflare proxy. | | |
| TASK-012 | Confirm SSL mode is Full by visiting `https://ch-paa-dev.acmeadventure.ca` — browser devtools should show a Cloudflare Universal SSL edge cert (issued by Google or Sectigo). | | |

### Phase 3 — Restrict LoadBalancer to Cloudflare IPs (Code — dev environment first)

- GOAL-003: Create `workloads/bootstrap/ngf-values.yaml` containing Cloudflare IP ranges as `loadBalancerSourceRanges`, update `aks-bootstrap.yml` to use the values file, and apply to the dev cluster. The Azure NSG will then only allow traffic from Cloudflare IP ranges on ports 80 and 443.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                              | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-014 | Create file `workloads/bootstrap/ngf-values.yaml` with the following content. Cloudflare IPv4 and IPv6 ranges sourced from https://www.cloudflare.com/ips-v4 and https://www.cloudflare.com/ips-v6 as of 2026-04-20. Include a comment with the source URL and date so the file can be refreshed when Cloudflare publishes range changes.<br><br>```yaml<br>nginx:<br>  service:<br>    type: LoadBalancer<br>    loadBalancerSourceRanges:<br>      # Cloudflare IPv4 — https://www.cloudflare.com/ips-v4 — 2026-04-20<br>      - 173.245.48.0/20<br>      - 103.21.244.0/22<br>      - 103.22.200.0/22<br>      - 103.31.4.0/22<br>      - 141.101.64.0/18<br>      - 108.162.192.0/18<br>      - 190.93.240.0/20<br>      - 188.114.96.0/20<br>      - 197.234.240.0/22<br>      - 198.41.128.0/17<br>      - 162.158.0.0/15<br>      - 104.16.0.0/13<br>      - 104.24.0.0/14<br>      - 172.64.0.0/13<br>      - 131.0.72.0/22<br>      # Cloudflare IPv6 — https://www.cloudflare.com/ips-v6 — 2026-04-20<br>      - 2400:cb00::/32<br>      - 2606:4700::/32<br>      - 2803:f800::/32<br>      - 2405:b500::/32<br>      - 2405:8100::/32<br>      - 2a06:98c0::/29<br>      - 2c0f:f248::/32<br>``` |           |      |
| TASK-015 | In `.github/workflows/aks-bootstrap.yml`, in the **`bootstrap-dev`** job, replace the `Bootstrap AKS — NGINX Gateway Fabric` step's `helm upgrade --install` command: remove `--set nginx.service.type=LoadBalancer` and add `-f workloads/bootstrap/ngf-values.yaml`. New command:<br><br>```bash<br>helm upgrade --install ngf \<br>  oci://ghcr.io/nginx/charts/nginx-gateway-fabric \<br>  --namespace gateway-system \<br>  --create-namespace \<br>  --version 2.5.0 \<br>  -f workloads/bootstrap/ngf-values.yaml \<br>  --wait --timeout 10m<br>``` |           |      |
| TASK-016 | Open a PR targeting `dev` with the TASK-014 and TASK-015 changes. After CI auto-applies in the dev environment, run the `AKS Bootstrap` workflow manually for dev to apply the updated Helm values. Confirm with `kubectl get svc -n gateway-system ngf-nginx-gateway-fabric -o yaml` that `spec.loadBalancerSourceRanges` lists all Cloudflare CIDR ranges.                                                          |           |      |
| TASK-017 | Verify the restriction is active for dev: from a non-Cloudflare IP (your workstation), attempt `curl -I --connect-to ch-paa-dev.acmeadventure.ca:443:<dev-lb-ip>:443 https://ch-paa-dev.acmeadventure.ca/` — expect a TCP timeout or connection refused (NSG blocks the direct connection). Then confirm `https://ch-paa-dev.acmeadventure.ca` still works normally via browser (goes through Cloudflare).           |           |      |

### Phase 4 — Apply Restriction to Prod (Code — prod environment)

- GOAL-004: Apply the same Helm values update to the prod bootstrap job, validate in prod.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | Completed | Date |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-018 | In `.github/workflows/aks-bootstrap.yml`, in the **`bootstrap-prod`** job, apply the same change as TASK-015: replace `--set nginx.service.type=LoadBalancer` with `-f workloads/bootstrap/ngf-values.yaml` in the NGINX Gateway Fabric Helm install step. | ✓ | 2026-04-27 |
| TASK-019 | Merge the PR to `dev`, then promote to `main` via a `dev → main` PR. After prod CI applies, run the `AKS Bootstrap` workflow manually for prod. Confirm `kubectl get svc -n gateway-system ngf-nginx-gateway-fabric -o yaml` shows `spec.loadBalancerSourceRanges` on the prod cluster. Verify `https://ch-paa.acmeadventure.ca` serves traffic through Cloudflare and direct LB IP access is blocked as in TASK-017. | | |

### Phase 5 — Remove `public_ip` Artifacts (Code + Manual)

- GOAL-005: Remove the now-unused `public_ip` Terraform variable, tfvars entries, and `PUBLIC_IP` GitHub secret. Update central tfvars in Blob Storage.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                               | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-020 | In `terraform/variables.tf`, remove the entire `variable "public_ip"` block. Confirmed — only remaining reference is in `containerapp.tf` inside a `/* */` comment block (ACA decommissioned). | ✓ | 2026-04-27 |
| TASK-021 | In `scripts/dev.tfvars`, remove the line `TF_VAR_public_ip = "50.99.81.3/32"`. Note: file is git-ignored; updated locally. | ✓ | 2026-04-27 |
| TASK-022 | In `scripts/prod.tfvars`, remove the line `TF_VAR_public_ip = "50.99.81.3/32"`. Note: file is git-ignored; updated locally. | ✓ | 2026-04-27 |
| TASK-023 | In `scripts/prod.tfvars.example`, remove the `TF_VAR_public_ip` line. | ✓ | 2026-04-27 |
| TASK-024 | Download both central tfvars files from Blob Storage, fix formatting with `terraform fmt`, and re-upload. Both `dev.auto.tfvars` and `prod.auto.tfvars` fixed (extra spaces before inline comments) and re-uploaded to `stpaatfstate2`. Neither file contained `public_ip`. Also removed `TF_VAR_public_ip` from `terraform-dev.yml` and `terraform-infra.yml` workflow env sections. | ✓ | 2026-04-27 |
| TASK-025 | Delete `PUBLIC_IP` GitHub secret from dev environment, prod environment, and repo-level Actions secrets. | ✓ | 2026-04-27 |
| TASK-026 | Run `terraform plan` against dev with no `TF_VAR_public_ip` set. Confirm plan shows no changes and no variable-not-defined errors. Pending merge of PR #48. | | |

### Phase 6 — Documentation Update (Code)

- GOAL-006: Update `ARCHITECTURE.md`, `workloads/bootstrap/README.md`, and the GitHub Secrets table to reflect the new ingress model.

| Task     | Description                                                                                                                                                                                                                                                                                                                                            | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-027 | In `ARCHITECTURE.md`, update the Shared Infrastructure bullet for **NGINX Gateway Fabric** to state that all public traffic is proxied through Cloudflare free tier before reaching the NGINX LoadBalancer. Update the **Security and Configuration** section to replace "IP-restricted HTTPS" with the Cloudflare proxy + LoadBalancer source range model. Remove the `PUBLIC_IP` row from the GitHub Secrets table. Remove `TF_VAR_public_ip` from the `dev.tfvars` description in the Central Terraform Variables section. |           |      |
| TASK-028 | In `workloads/bootstrap/README.md`, update the **Phase 2 — DNS Records** section to note that records must be created as **Proxied** in Cloudflare (not as raw A records pointing at the LB IP). Update the `dig` validation commands to note that after TASK-011, `dig` will return Cloudflare anycast IPs. Add a note that the LB IP table is no longer published in public docs (treat LB IP as sensitive once the restriction is active). Add a note above the Pinned Chart Versions table: `ngf-values.yaml` Cloudflare IP ranges should be refreshed if Cloudflare publishes updates (source: https://www.cloudflare.com/ips-v4 and https://www.cloudflare.com/ips-v6). |           |      |

## 3. Alternatives

- **ALT-001: Cloudflare Tunnel (Zero Trust)** — Routes traffic from origin to Cloudflare via an outbound mTLS tunnel (no inbound port required). On free tier, outbound tunnel throughput is throttled. More complex to operate with NGINX Gateway Fabric on AKS. Chosen approach (DNS proxy + LB source ranges) is simpler and well-supported on free tier.
- **ALT-002: Cloudflare Authenticated Origin Pulls (mTLS)** — Cloudflare sends a client certificate with every origin request; NGINX can be configured to reject connections without it. Provides a cryptographic guarantee (not just IP-based) that traffic originates from Cloudflare. Not adopted in this plan because it requires NGINX to be configured with a client CA — complex with NGINX Gateway Fabric's current abstraction. Recommend as a Phase 5 hardening after this plan is complete.
- **ALT-003: Terraform Cloudflare Provider** — Manage Cloudflare DNS and zone settings declaratively in Terraform (registry.terraform.io/providers/cloudflare/cloudflare). Keeps all infra in one place and allows audit trails. Not adopted in this plan to minimize scope; Cloudflare dashboard sufficient for initial setup. Recommend for a follow-up plan.
- **ALT-004: DNS-01 cert-manager Challenges** — Instead of HTTP-01 challenges through Cloudflare proxy, use DNS-01 with the Cloudflare DNS API. Avoids all HTTP-01/Cloudflare interaction concerns entirely. Requires a Cloudflare API token stored as a Kubernetes Secret, and updating ClusterIssuer to use `dns01` solver. Not adopted here to keep scope minimal; HTTP-01 works through Cloudflare proxy when "Always Use HTTPS" is off. Recommend as follow-up — especially if Cloudflare "Always Use HTTPS" or HSTS preload ever needs to be enabled.
- **ALT-005: Azure Front Door or Application Gateway** — Azure-native CDN/WAF options. More expensive than Cloudflare free tier; Azure Front Door Standard starts at ~$35/month. Not aligned with cost goals.

## 4. Dependencies

- **DEP-001**: DNS for `acmeadventure.ca` is currently managed outside Cloudflare. Registrar change of nameservers is required. The PR implementing TASK-014 and TASK-015 can be merged before nameserver delegation is complete — AKS bootstrap just re-applies idempotently.
- **DEP-002**: cert-manager HTTP-01 solver must have port 80 reachable through Cloudflare. The `http` Gateway listener on port 80 must remain in `gateway.yaml` (do not remove it as part of this change).
- **DEP-003**: Let's Encrypt certificates at origin must be valid (READY) before switching Cloudflare SSL/TLS mode to Full (Strict). If any cert is expired or in error state, fix it before Phase 1 begins.
- **DEP-004**: Dev and prod clusters exist and are reachable from CI. The `AKS Bootstrap` GitHub Actions workflow must be manually triggered after the PR lands to re-apply Helm values with `loadBalancerSourceRanges`.

## 5. Files

- **FILE-001**: `workloads/bootstrap/ngf-values.yaml` — **New.** NGINX Gateway Fabric Helm values file; declares `loadBalancerSourceRanges` with all Cloudflare IPv4 and IPv6 CIDR ranges. Replaces the `--set nginx.service.type=LoadBalancer` inline flag.
- **FILE-002**: `.github/workflows/aks-bootstrap.yml` — **Modified.** Both `bootstrap-dev` and `bootstrap-prod` jobs: NGF Helm install changes `--set nginx.service.type=LoadBalancer` to `-f workloads/bootstrap/ngf-values.yaml`.
- **FILE-003**: `terraform/variables.tf` — **Modified.** Remove the `variable "public_ip"` block entirely.
- **FILE-004**: `scripts/dev.tfvars` — **Modified.** Remove `TF_VAR_public_ip = "50.99.81.3/32"`.
- **FILE-005**: `scripts/prod.tfvars` — **Modified.** Remove `TF_VAR_public_ip = "50.99.81.3/32"`.
- **FILE-006**: `scripts/prod.tfvars.example` — **Modified.** Remove `TF_VAR_public_ip = "<your-home-ip>/32"` and comment.
- **FILE-007**: `workloads/bootstrap/README.md` — **Modified.** Update Phase 2 DNS section; note Cloudflare proxied records; redact LB IP from public docs; add Cloudflare IP range refresh note.
- **FILE-008**: `ARCHITECTURE.md` — **Modified.** Update NGINX section description, Security section, GitHub Secrets table, and dev.tfvars description.

## 6. Testing

- **TEST-001**: After TASK-010 (proxied DNS), confirm `dig {hostname}` returns Cloudflare anycast IPs (not `52.191.18.153` or `172.171.181.166`) for all five hostnames.
- **TEST-002**: After TASK-010, confirm `https://{hostname}` loads correctly for all dev and prod instances. SSL cert shown in browser is Cloudflare Universal SSL.
- **TEST-003**: After TASK-011, confirm all cert-manager `Certificate` resources show `READY=True`. Trigger manual renewal on dev instance to confirm HTTP-01 solver works through Cloudflare.
- **TEST-004**: After TASK-016/TASK-019, confirm `kubectl get svc -n gateway-system ngf-nginx-gateway-fabric -o jsonpath='{.spec.loadBalancerSourceRanges}'` lists all 22 Cloudflare CIDR ranges on both dev and prod clusters.
- **TEST-005**: After TASK-017/TASK-019, confirm direct LB IP access is blocked: `curl --max-time 10 -I https://<lb-ip> --resolve "ch-paa-dev.acmeadventure.ca:<lb-ip>"` should time out or return connection refused.
- **TEST-006**: After TASK-026, run `terraform plan` for dev — confirm clean plan with zero changes and no unknown variable errors.
- **TEST-007**: After Phase 5 cleanup, confirm the CI pipeline runs successfully end-to-end in dev (Terraform Dev workflow).

## 7. Risks & Assumptions

- **RISK-001**: Applying `loadBalancerSourceRanges` before confirming Cloudflare DNS is proxied will cut off all direct HTTPS traffic. Mitigation: the plan requires explicit verification at TASK-011 before any NSG change is applied (TASK-014 onwards).
- **RISK-002**: Cloudflare NS delegation can take up to 24 hours. During this window, some clients may hit the old NS and get the direct LB IP. DNS records remain usable in grey-cloud during transition.
- **RISK-003**: cert-manager certificate renewal falls during a Cloudflare outage. Mitigated by cert-manager's 30-day renewal window (renewals attempted well before expiry).
- **RISK-004**: Cloudflare changes its IP ranges. The `ngf-values.yaml` file would need updating; until refreshed, new Cloudflare IPs would be blocked at the NSG. Mitigated by the low frequency of Cloudflare IP range changes and the monitoring note in FILE-007.
- **RISK-005**: `terraform plan` after removing `public_ip` variable may produce a warning if the central tfvars file in Blob Storage still contains `public_ip = ...`. This is a warning not an error, but TASK-024 should be run before CI applies Terraform with the variable removed.
- **ASSUMPTION-001**: DNS for `acmeadventure.ca` is managed at a registrar that allows NS record changes. This is standard for any ICANN domain registration.
- **ASSUMPTION-002**: The Let's Encrypt certs managed by cert-manager on both clusters are currently READY (confirmed by the active deployment state before this plan).
- **ASSUMPTION-003**: NGINX Gateway Fabric 2.5.0's Helm chart respects `nginx.service.loadBalancerSourceRanges` and translates it to the Kubernetes Service `spec.loadBalancerSourceRanges` field, which AKS then enforces via Azure NSG rules.

## 8. Related Specifications / Further Reading

- [Cloudflare IP ranges](https://www.cloudflare.com/ips/) — canonical source for IP range updates
- [Cloudflare Free plan features](https://www.cloudflare.com/plans/free/) — WAF, DDoS, Bot Fight Mode
- [Cloudflare SSL/TLS modes](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/)
- [cert-manager HTTP-01 challenge via Cloudflare proxy](https://cert-manager.io/docs/configuration/acme/http01/)
- [Kubernetes loadBalancerSourceRanges](https://kubernetes.io/docs/tasks/access-application-cluster/create-external-load-balancer/#filtering-by-source-ip)
- [NGINX Gateway Fabric Helm values reference](https://docs.nginx.com/nginx-gateway-fabric/installation/installing-ngf/helm/)
- [../../ARCHITECTURE.md](../../ARCHITECTURE.md)
- [../../workloads/bootstrap/README.md](../../workloads/bootstrap/README.md)
- [../../.github/workflows/aks-bootstrap.yml](../../.github/workflows/aks-bootstrap.yml)
