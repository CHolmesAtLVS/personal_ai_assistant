# AKS Platform Bootstrap — Operator Notes

All bootstrap steps run automatically in CI (`terraform-deploy.yml`) after `terraform apply`
completes. The notes below cover the manual follow-up actions required after each phase.

---

## Phase 2 — DNS Records

After NGINX Gateway Fabric is installed, capture the LoadBalancer external IP:

```bash
kubectl get svc -n gateway-system ngf-nginx-gateway-fabric
```

Set DNS A records in the `acmeadventure.ca` zone:

| Hostname                    | Record | Value          |
| --------------------------- | ------ | -------------- |
| `paa-dev.acmeadventure.ca`  | A      | `<dev-lb-ip>`  |
| `paa.acmeadventure.ca`      | A      | `<prod-lb-ip>` |

<!-- Update the IPs below after each bootstrap run. -->
| Environment | LoadBalancer IP    | Last Updated |
| ----------- | ------------------ | ------------ |
| dev         | `52.191.18.153`    | 2026-04-19   |
| prod        | `172.171.181.166`  | 2026-04-19   |

**Wait for full DNS propagation before triggering Phase 3 CI (cert-manager ClusterIssuer
validation).** HTTP-01 ACME challenges require the ACME server to resolve the hostname and
reach port 80 on the cluster.

Validate before proceeding:
```bash
dig paa-dev.acmeadventure.ca +short   # must return the dev LB IP
dig paa.acmeadventure.ca +short       # must return the prod LB IP
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

| Component            | Chart version | Pinned at  | Managed by      |
| -------------------- | ------------- | ---------- | --------------- |
| nginx-gateway-fabric | 2.5.0         | 2026-04-08 | Terraform       |
| cert-manager         | 1.20.1        | 2026-04-08 | Terraform       |
| Gateway API CRDs     | v1.2.1        | 2026-04-08 | CI bootstrap    |
| argo-cd              | 9.4.17        | 2026-04-08 | CI bootstrap    |
| CSI Driver + AKV     | AKS-managed   | —          | Terraform (AKS) |
