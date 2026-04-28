# Graph Report - .  (2026-04-28)

## Corpus Check
- Corpus is ~27,335 words - fits in a single context window. You may not need a graph.

## Summary
- 53 nodes · 89 edges · 7 communities detected
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 1 edges (avg confidence: 0.5)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 4|Community 4]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]

## God Nodes (most connected - your core abstractions)

## Surprising Connections (you probably didn't know these)
- `AKS Cluster` --serves--> `Prod Environment`  [INFERRED]
   →   _Bridges community 3 → community 1_
- `NGINX Gateway Fabric` --routes_traffic_to--> `OpenClaw Instance (per-instance)`  [EXTRACTED]
   →   _Bridges community 1 → community 4_
- `Secrets Store CSI Driver` --injects_secrets_into--> `OpenClaw Instance (per-instance)`  [EXTRACTED]
   →   _Bridges community 1 → community 0_
- `OpenClaw Instance (per-instance)` --stores_state_in--> `Azure Disk PVC (managed-csi-premium)`  [EXTRACTED]
   →   _Bridges community 1 → community 6_
- `Azure Container Registry` --provides_image_to--> `OpenClaw Instance (per-instance)`  [EXTRACTED]
   →   _Bridges community 1 → community 2_

## Hyperedges (group relationships)
- **** —  [EXTRACTED]
- **** —  [EXTRACTED]
- **** —  [INFERRED]

## Communities

### Community 0 - "Community 0"
Cohesion: 0.0
Nodes (10): Azure AI Foundry / AI Services, Azure Key Vault, Secrets Store CSI Driver, gpt-5.4-mini (Primary Chat Model), Log Analytics Workspace, Azure Managed Identity (Workload Identity), Observability Blob Storage, Plan: Observability and Hygiene (+2 more)

### Community 1 - "Community 1"
Cohesion: 0.0
Nodes (10): openclaw-aca-operations.md, ArgoCD, ArgoCD ApplicationSet, argocd/apps/README.md, ConfigMap (openclaw-env-config), OpenClaw Helm Chart (serhanekicii/openclaw-helm), HTTPRoute, Kubernetes NetworkPolicy (+2 more)

### Community 2 - "Community 2"
Cohesion: 0.0
Nodes (9): Azure Container Registry, Azure Blob Storage (Terraform State), Central Terraform Variables File, Azure Consumption Budget, CONTRIBUTING.md, GitHub Actions CI/CD, Public GitHub Repository, Azure Service Principal (+1 more)

### Community 3 - "Community 3"
Cohesion: 0.0
Nodes (7): AKS Cluster, Azure Automation Account, Dev Environment, Plan: Dev Cluster Stop-Only Cost, readme.md, start-dev-cluster.ps1, stop-dev-cluster.ps1

### Community 4 - "Community 4"
Cohesion: 0.0
Nodes (6): workloads/bootstrap/README.md, cert-manager + Let's Encrypt, Cloudflare WAF/Proxy, ngf-values.yaml (Cloudflare CIDRs), NGINX Gateway Fabric, Plan: Cloudflare Proxy/WAF Feature

### Community 5 - "Community 5"
Cohesion: 0.0
Nodes (5): ARCHITECTURE.md, OpenClaw Application, Plan: Backup Cleanup and Docs, Plan: Storage Audit (Deprecated), PRODUCT.md

### Community 6 - "Community 6"
Cohesion: 0.0
Nodes (4): Azure Disk PVC (managed-csi-premium), openclaw CLI, openclaw-connect.sh, Plan: Personal Setup Guide