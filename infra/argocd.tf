// ArgoCD bootstrap.
//
// This is the one place Terraform touches Kubernetes, and it is deliberate:
// something has to install ArgoCD before ArgoCD can manage anything.
//
// After the root Application exists, ArgoCD owns its own installation (the
// `argocd` Application is part of the platform app set). Terraform is then told
// to stop managing the Helm release via `lifecycle.ignore_changes`, so the two
// systems never fight over the same objects.

terraform {
  required_providers {
    helm = { source = "hashicorp/helm" }
    kubectl = { source = "alekc/kubectl" }
    kubernetes = { source = "hashicorp/kubernetes" }
  }
}

# ---------------------------------------------------------------------------
# Provider authentication: Azure AD (no static cluster credentials).
# ---------------------------------------------------------------------------

data "azurerm_kubernetes_cluster" "this" {
  name                = azurerm_kubernetes_cluster.this.name
  resource_group_name = azurerm_resource_group.platform.name
}

provider "kubernetes" {
  host                   = data.azurerm_kubernetes_cluster.this.kube_config[0].host
  client_certificate     = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].client_certificate)
  client_key             = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = data.azurerm_kubernetes_cluster.this.kube_config[0].host
    client_certificate     = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].client_certificate)
    client_key             = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)
  }
}

provider "kubectl" {
  host                   = data.azurerm_kubernetes_cluster.this.kube_config[0].host
  client_certificate     = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].client_certificate)
  client_key             = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)
  load_config_file       = false
}

# ---------------------------------------------------------------------------
# Namespaces that must exist before ArgoCD (chicken and egg).
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      "app.kubernetes.io/part-of"    = "platform"
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}

# ---------------------------------------------------------------------------
# ArgoCD itself
# ---------------------------------------------------------------------------

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  # ArgoCD is the thing that makes Git the source of truth, so its own config is
  # set here once and then owned by Git via the platform Application.
  values = [yamlencode({
    global = {
      domain = "argocd.${var.environment}.example.com"
    }
    configs = {
      params = {
        # Poll Git every 3 minutes. Webhooks make this near-instant for pushes
        # from CI; the poll is the safety net for a missed webhook.
        "timeout.reconciliation" = "180s"
        "server.insecure"        = false
      }
      cm = {
        # Only main may be synced. This is the GitOps property 4 guard.
        "application.instanceLabelKey" = "argocd.argoproj.io/instance"
        "url"                          = "https://argocd.${var.environment}.example.com"
      }
      rbac = {
        # Admin account disabled; humans authenticate through OIDC and are
        # mapped to roles by Entra ID group.
        "policy.default" = "role:readonly"
        "policy.csv" = join("\n", [
          "g, argocd-admins, role:admin",
          "g, developers, role:readonly",
          "p, role:readonly, applications, get, */*, allow",
          "p, role:readonly, logs, get, */*, allow",
        ])
      }
    }
    server = {
      replicas = var.environment == "prod" ? 2 : 1
    }
    controller = {
      replicas = 1
      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { memory = "2Gi" }
      }
    }
    repoServer = {
      replicas = var.environment == "prod" ? 2 : 1
    }
    # The admin account is disabled entirely: no static password to leak.
    extraObjects = []
  })]

  # Once ArgoCD manages itself (via the platform ApplicationSet), Terraform must
  # stop fighting it.
  lifecycle {
    ignore_changes = [values, version]
  }
}

# ---------------------------------------------------------------------------
# Disable the built-in admin account explicitly.
# ---------------------------------------------------------------------------

resource "kubectl_manifest" "argocd_disable_admin" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "argocd-secret"
      namespace = "argocd"
    }
    stringData = {
      "admin.password"     = ""
      "admin.passwordMtime" = ""
    }
  })

  depends_on = [helm_release.argocd]
}

# ---------------------------------------------------------------------------
# The root Application: app-of-apps.
#
# This single object is the handover point. Everything Argo will ever manage is
# reachable from here, and nothing else needs cluster credentials.
# ---------------------------------------------------------------------------

resource "kubectl_manifest" "root_app" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root"
      namespace = "argocd"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = var.gitops_revision
        path           = "clusters/${var.environment}"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["CreateNamespace=false", "ApplyOutOfSyncOnly=true"]
        retry = {
          limit = 5
          backoff = {
            duration    = "10s"
            factor      = 2
            maxDuration = "3m"
          }
        }
      }
    }
  })

  depends_on = [helm_release.argocd, kubectl_manifest.argocd_disable_admin]
}

output "argocd_server" {
  value = "argocd.${var.environment}.example.com"
}

output "root_application" {
  value = "argocd/root"
}
