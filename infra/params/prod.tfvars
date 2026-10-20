environment     = "prod"
location        = "centralindia"
name_prefix     = "gitp"
kubernetes_version = "1.30"

system_node_pool = {
  vm_size   = "Standard_D4s_v5"
  min_count = 3
  max_count = 5
  zones     = ["1", "2", "3"]
}

workload_node_pool = {
  vm_size   = "Standard_D4s_v5"
  min_count = 2
  max_count = 10
  zones     = ["1", "2", "3"]
  spot      = false
}

admin_group_object_id = ""

tags = {
  project            = "gitops-aks-argocd"
  environment        = "prod"
  owner              = "platform-team"
  costCentre         = "platform-001"
  dataClassification = "internal"
}
