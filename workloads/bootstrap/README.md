# AKS Platform Bootstrap — Operator Notes

All bootstrap steps run automatically in CI (`terraform-deploy.yml`) after `terraform apply`
completes. The notes below cover the manual follow-up actions required after each phase.

---

## Phase 2 — DNS Records

All public hostnames for `acmeadventure.ca` are **proxied through Cloudflare** (orange-cloud DNS records). DNS records must be created as **Proxied** in the Cloudflare dashboard — not as bare A records pointing at the LoadBalancer IP. The LoadBalancer IP must not appear in public DNS.

After NGINX Gateway Fabric is installed, capture the LoadBalancer external IP (treat this as sensitive — do not publish it):

```bash
kubectl get svc -n gateway-system ngf-nginx-gateway-fabric
```

In the Cloudflare dashboard (**DNS → Records**), create the following A records with **Proxied** toggled on (orange cloud):

| Hostname | Record | Value |
| -------- | ------ | ----- |
| `ch-paa-dev.acmeadventure.ca` | A | `<dev-lb-ip>` (Proxied) |
| `jh-paa-dev.acmeadventure.ca` | A | `<dev-lb-ip>` (Proxied) |
| `ch-paa.acmeadventure.ca` | A | `<prod-lb-ip>` (Proxied) |
| `jh-paa.acmeadventure.ca` | A | `<prod-lb-ip>` (Proxied) |
| `kjm-paa.acmeadventure.ca` | A | `<prod-lb-ip>` (Proxied) |

Hostnames use hyphens (not dots) because Cloudflare Universal SSL only covers one subdomain level.

**Wait for full DNS propagation and confirm Cloudflare proxy is active before triggering Phase 3 CI (cert-manager ClusterIssuer validation).**

Validate before proceeding (after Cloudflare is proxied, `dig` returns Cloudflare anycast IPs, not the LB IP):
```bash
dig ch-paa-dev.acmeadventure.ca +short   # must return Cloudflare anycast IPs
dig ch-paa.acmeadventure.ca +short       # must return Cloudflare anycast IPs
```

---

## Phase 3 — GitHub Secret Required

Before the `Bootstrap AKS — ClusterIssuers` CI step runs, add the following secret to both
the `dev` and `prod` GitHub Actions environments (repository **Settings → Environments → Secrets**):

| Secret name         | Value                      |
| ------------------- | -------------------------- |
| `LETSENCRYPT_EMAIL` | `craig.holmes.32@gmail.com` |

The `cluster-issuers.yaml` manifest uses `${LETSENCRYPT_EMAIL}` as an envsubst placeholder —
the real address is never committed to the repository.

Start with `letsencrypt-staging` to validate ACME before switching to `letsencrypt-prod` to
avoid Let's Encrypt rate limits.

---

## Phase 4 — ArgoCD Initial Admin Password

ArgoCD is **not** exposed via the Gateway. Access is via `kubectl port-forward` only.

After Phase 4 CI completes:

1. Start a port-forward:
   ```bash
   kubectl port-forward svc/argocd-server -n argocd 8080:80
   ```
2. Retrieve the auto-generated password:
   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath="{.data.password}" | base64 -d && echo
   ```
3. Store in your password manager immediately.
4. Open `http://localhost:8080` and log in with user `admin` and the password above.
5. Rotate the password via **User Info → Update Password** in the UI, or via CLI:
   ```bash
   argocd login localhost:8080 --username admin --password <password> --plaintext
   argocd account update-password
   ```
6. Delete the bootstrap secret after rotation:
   ```bash
   kubectl -n argocd delete secret argocd-initial-admin-secret
   ```

**Do not commit the initial password or leave the bootstrap secret in place.**

---

## Pinned Chart Versions

The Secrets Store CSI Driver and Azure Key Vault Provider are installed by the AKS
`key_vault_secrets_provider` add-on declared in Terraform — they are not managed here.

> **Cloudflare IP range refresh:** `workloads/bootstrap/ngf-values.yaml` contains the
> `loadBalancerSourceRanges` for the NGINX LoadBalancer. These must be refreshed if Cloudflare
> publishes IP range updates. Canonical sources:
> https://www.cloudflare.com/ips-v4 and https://www.cloudflare.com/ips-v6

| Component            | Chart version | Pinned at  | Managed by      |
| -------------------- | ------------- | ---------- | --------------- |
| nginx-gateway-fabric | 2.5.0         | 2026-04-08 | Terraform       |
| cert-manager         | 1.20.1        | 2026-04-08 | Terraform       |
| Gateway API CRDs     | v1.2.1        | 2026-04-08 | CI bootstrap    |
| argo-cd              | 9.4.17        | 2026-04-08 | CI bootstrap    |
| CSI Driver + AKV     | AKS-managed   | —          | Terraform (AKS) |
