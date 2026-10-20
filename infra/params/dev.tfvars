environment     = "dev"
location        = "centralindia"
name_prefix     = "gito"
kubernetes_version = "1.30"

system_node_pool = {
  vm_size   = "Standard_D2s_v5"
  min_count = 1
  max_count = 2
  zones     = ["1", "2"]
}

workload_node_pool = {
  vm_size   = "Standard_D2s_v5"
  min_count = 1
  max_count = 3
  zones     = ["1", "2"]
  spot      = true
}

admin_group_object_id = ""

tags = {
  project            = "gitops-aks-argocd"
  environment        = "dev"
  owner              = "platform-team"
  costCentre         = "platform-001"
  dataClassification = "internal"
}
