# ── AKS Platform Bootstrap — Helm releases ───────────────────────────────────
# These releases run in the same terraform apply as the cluster.
# Versions here must stay in sync with workloads/bootstrap/README.md.

# ── Phase 2: NGINX Gateway Fabric ────────────────────────────────────────────
# Creates GatewayClass "nginx" and a LoadBalancer service in gateway-system.
# After first apply, retrieve the external IP and set DNS A records:
#   kubectl get svc -n gateway-system ngf-nginx-gateway-fabric
resource "helm_release" "nginx_gateway_fabric" {
  name             = "ngf"
  repository       = "oci://ghcr.io/nginx/charts"
  chart            = "nginx-gateway-fabric"
  namespace        = "gateway-system"
  create_namespace = true
  version          = "2.5.0"
  wait             = true
  timeout          = 600

  set {
    name  = "nginx.service.type"
    value = "LoadBalancer"
  }

  depends_on = [module.aks]
}

# ── Phase 3: cert-manager ─────────────────────────────────────────────────────
# Installs cert-manager with Gateway API support (beta, default-on in 1.20+).
# ClusterIssuers are applied via kubectl in CI after this — they depend on the
# cert-manager CRDs being present and the LETSENCRYPT_EMAIL secret being set.
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  version          = "1.20.1"
  wait             = true
  timeout          = 300

  set {
    name  = "crds.enabled"
    value = "true"
  }

  depends_on = [module.aks]
}
