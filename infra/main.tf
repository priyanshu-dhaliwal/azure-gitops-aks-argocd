// Terraform: AKS cluster + platform prerequisites.
//
// Ownership boundary (see README): Terraform creates the cluster and every Azure
// resource the cluster depends on. It does NOT create Kubernetes objects, with
// one exception — the ArgoCD bootstrap, which is then handed over to ArgoCD.

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.32"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

variable "environment" {
  type        = string
  description = "dev | prod"
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "location" { type = string }
variable "name_prefix" { type = string }

variable "kubernetes_version" {
  type    = string
  default = "1.30"
}

variable "system_node_pool" {
  type = object({
    vm_size    = string
    min_count  = number
    max_count  = number
    zones      = list(string)
  })
  default = {
    vm_size   = "Standard_D4s_v5"
    min_count = 3
    max_count = 5
    zones     = ["1", "2", "3"]
  }
}

variable "workload_node_pool" {
  type = object({
    vm_size    = string
    min_count  = number
    max_count  = number
    zones      = list(string)
    spot       = bool
  })
  default = {
    vm_size   = "Standard_D4s_v5"
    min_count = 2
    max_count = 10
    zones     = ["1", "2", "3"]
    spot      = false
  }
}

variable "argocd_chart_version" {
  type    = string
  default = "7.6.12"
}

variable "gitops_repo_url" {
  type        = string
  description = "Git URL ArgoCD reads from"
  default     = "https://github.com/priyanshu-dhaliwal/azure-gitops-aks-argocd.git"
}

variable "gitops_revision" {
  type        = string
  description = "Branch ArgoCD follows. Only main is allowed."
  default     = "main"
  validation {
    condition     = var.gitops_revision == "main"
    error_message = "ArgoCD may only follow main. Change the branch, not this variable."
  }
}

variable "admin_group_object_id" {
  type        = string
  description = "Entra ID group that gets ArgoCD admin via OIDC"
  default     = ""
}

variable "tags" {
  type = map(string)
  default = {
    project = "gitops-aks-argocd"
    managed = "terraform"
  }
}

locals {
  name = "${var.name_prefix}-${var.environment}"

  # Platform namespaces are created by Argo (wave 0), but Kyverno and
  # external-secrets need their namespaces to exist before their CRDs are used.
  platform_namespaces = ["ingress-nginx", "cert-manager", "external-secrets",
  "kyverno", "monitoring", "argocd", "api", "worker"]
}

# ---------------------------------------------------------------------------
# Resource groups
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "platform" {
  name     = "rg-${local.name}-platform"
  location = var.location
  tags = merge(var.tags, {
    environment        = var.environment
    owner              = "platform-team"
    costCentre         = "platform-001"
    dataClassification = "internal"
  })
}

# ---------------------------------------------------------------------------
# Networking: a small dedicated VNet, egress via Azure Firewall.
# (A full landing zone lives in the zero-trust project; this one is
# self-contained so the repo can be deployed on its own.)
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${local.name}"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  address_space       = ["10.60.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "snet-aks"
  resource_group_name  = azurerm_resource_group.platform.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.60.0.0/20"]
}

resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.platform.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.60.16.0/24"]
}

resource "azurerm_public_ip" "firewall" {
  name                = "pip-${local.name}-fw"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_firewall" "this" {
  name                = "afw-${local.name}"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"
  tags                = var.tags

  ip_configuration {
    name                 = "fw-ipconfig"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall.id
  }
}

resource "azurerm_route_table" "aks" {
  name                = "rt-${local.name}-aks"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = var.tags

  # Forced tunnelling: all egress leaves through the firewall, so image pulls and
  # any unexpected traffic are visible in one place.
  route {
    name                   = "default-to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.this.ip_configuration[0].private_ip_address
  }
}

resource "azurerm_subnet_route_table_association" "aks" {
  subnet_id      = azurerm_subnet.aks.id
  route_table_id = azurerm_route_table.aks.id
}

# ---------------------------------------------------------------------------
# ACR + Key Vault (images and secrets; both reached via private endpoint)
# ---------------------------------------------------------------------------

resource "azurerm_container_registry" "this" {
  name                          = replace("${var.name_prefix}${var.environment}acr", "-", "")
  resource_group_name           = azurerm_resource_group.platform.name
  location                      = azurerm_resource_group.platform.location
  sku                           = "Premium"
  admin_enabled                 = false
  public_network_access_enabled = false
  zone_redundancy_enabled       = true
  tags                          = var.tags
}

resource "azurerm_key_vault" "this" {
  name                          = "kv-${local.name}-${substr(sha1(azurerm_resource_group.platform.id), 0, 5)}"
  location                      = azurerm_resource_group.platform.location
  resource_group_name           = azurerm_resource_group.platform.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  enable_rbac_authorization     = true
  purge_protection_enabled      = true
  public_network_access_enabled = false
  tags                          = var.tags
}

resource "azurerm_private_dns_zone" "vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.platform.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "vault" {
  name                  = "link-${local.name}"
  resource_group_name   = azurerm_resource_group.platform.name
  private_dns_zone_name = azurerm_private_dns_zone.vault.name
  virtual_network_id    = azurerm_virtual_network.this.id
}

resource "azurerm_private_endpoint" "vault" {
  name                = "pe-${local.name}-kv"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  subnet_id           = azurerm_subnet.aks.id
  tags                = var.tags

  private_service_connection {
    name                           = "kv-psc"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.vault.id]
  }
}

# ---------------------------------------------------------------------------
# Log Analytics + Container Insights
# ---------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "this" {
  name                = "law-${local.name}"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  sku                 = "PerGB2018"
  retention_in_days   = var.environment == "prod" ? 90 : 30
  daily_quota_gb      = var.environment == "prod" ? 10 : 3
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# AKS
# ---------------------------------------------------------------------------

resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${local.name}"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  dns_prefix          = "aks-${local.name}"
  kubernetes_version  = var.kubernetes_version
  tags                = var.tags

  # GitOps property 1: no local accounts. There is no static kubeconfig that
  # works forever, so nobody can kubectl from a laptop with a leaked credential.
  local_account_disabled = true

  # Azure RBAC for Kubernetes authorization: cluster access is an Entra ID
  # group membership, not a certificate in a file.
  role_based_access_control_enabled = true
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled     = true
    admin_group_object_ids = var.admin_group_object_id == "" ? [] : [var.admin_group_object_id]
  }

  oidc_issuer_enabled       = true   # required for workload identity
  workload_identity_enabled = true

  default_node_pool {
    name                 = "system"
    vm_size              = var.system_node_pool.vm_size
    min_count            = var.system_node_pool.min_count
    max_count            = var.system_node_pool.max_count
    zones                = var.system_node_pool.zones
    vnet_subnet_id       = azurerm_subnet.aks.id
    os_disk_size_gb      = 128
    os_disk_type         = "Ephemeral"
    only_critical_addons_enabled = true
    node_labels = {
      "nodepool-type" = "system"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    load_balancer_sku   = "standard"
    outbound_type       = "userDefinedRouting"   # forced tunnelling via firewall
    pod_cidr            = "192.168.0.0/16"
    service_cidr        = "10.100.0.0/16"
    dns_service_ip      = "10.100.0.10"
  }

  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.this.id
    msi_auth_for_monitoring_enabled = true
  }

  # Kyverno and ingress need the admission webhooks to be ready before workloads;
  # the cluster-level guard is that we never install workloads before Argo is up.
  workload_autoscaler_profile {
    keda_enabled                    = true
    vertical_pod_autoscaler_enabled = true
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  lifecycle {
    # Kubernetes version is pinned and upgraded deliberately, never as a side
    # effect of a terraform apply.
    ignore_changes = [kubernetes_version]
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "workload" {
  name                  = "workload"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.workload_node_pool.vm_size
  min_count             = var.workload_node_pool.min_count
  max_count             = var.workload_node_pool.max_count
  zones                 = var.workload_node_pool.zones
  vnet_subnet_id        = azurerm_subnet.aks.id
  priority              = var.workload_node_pool.spot ? "Spot" : "Regular"
  eviction_policy       = var.workload_node_pool.spot ? "Delete" : null
  spot_max_price        = var.workload_node_pool.spot ? "-1" : null
  os_disk_size_gb       = 128
  mode                  = "User"
  tags                  = var.tags

  node_labels = {
    "nodepool-type" = "workload"
  }
  node_taints = ["workload=true:NoSchedule"]
}

# Let the kubelet pull from ACR without an image pull secret.
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

# ---------------------------------------------------------------------------
# Workload identities: one per application, federated to a ServiceAccount.
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "apps" {
  for_each = toset(["api", "worker"])

  name                = "id-${local.name}-${each.key}"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "apps" {
  for_each = azurerm_user_assigned_identity.apps

  name                      = "${each.key}-sa"
  user_assigned_identity_id = each.value.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject                   = "system:serviceaccount:${each.key}:${each.key}"
}

# Each app may read secrets from the vault, and nothing else.
resource "azurerm_role_assignment" "app_secrets" {
  for_each = azurerm_user_assigned_identity.apps

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value.principal_id
}

data "azurerm_client_config" "current" {}

# ---------------------------------------------------------------------------
# Outputs consumed by the bootstrap script and by Argo
# ---------------------------------------------------------------------------

output "cluster_name" { value = azurerm_kubernetes_cluster.this.name }
output "resource_group" { value = azurerm_resource_group.platform.name }
output "oidc_issuer_url" { value = azurerm_kubernetes_cluster.this.oidc_issuer_url }
output "acr_login_server" { value = azurerm_container_registry.this.login_server }
output "key_vault_uri" { value = azurerm_key_vault.this.vault_uri }

output "app_identity_client_ids" {
  value = { for k, v in azurerm_user_assigned_identity.apps : k => v.client_id }
}

output "platform_namespaces" { value = local.platform_namespaces }
