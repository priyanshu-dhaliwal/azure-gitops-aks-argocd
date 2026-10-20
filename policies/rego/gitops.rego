# conftest policies for the rendered manifests.
#
# These run in CI on the *rendered* output, which is what Argo will actually
# apply. They are the last line of defence before a bad manifest reaches the
# cluster; Kyverno is the runtime enforcement after it does.
package main

# ---------------------------------------------------------------------------
# No :latest images — a tag that can change without a commit is not GitOps.
# ---------------------------------------------------------------------------
deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  endswith(container.image, ":latest")
  msg := sprintf("Deployment %s uses :latest — pin the tag", [input.metadata.name])
}

deny[msg] {
  input.kind == "Rollout"
  container := input.spec.template.spec.containers[_]
  endswith(container.image, ":latest")
  msg := sprintf("Rollout %s uses :latest — pin the tag", [input.metadata.name])
}

# ---------------------------------------------------------------------------
# Every container declares a memory limit. Without one, a leaky pod evicts its
# neighbours.
# ---------------------------------------------------------------------------
deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.resources.limits.memory
  msg := sprintf("Deployment %s container %s has no memory limit", [input.metadata.name, container.name])
}

deny[msg] {
  input.kind == "Rollout"
  container := input.spec.template.spec.containers[_]
  not container.resources.limits.memory
  msg := sprintf("Rollout %s container %s has no memory limit", [input.metadata.name, container.name])
}

# ---------------------------------------------------------------------------
# Accountability labels, mirroring the Kyverno policy so a PR fails before merge
# rather than at admission time.
# ---------------------------------------------------------------------------
deny[msg] {
  input.kind == "Deployment"
  not input.spec.template.metadata.labels.owner
  msg := sprintf("Deployment %s pod template is missing the owner label", [input.metadata.name])
}

deny[msg] {
  input.kind == "Deployment"
  not input.spec.template.metadata.labels["cost-centre"]
  msg := sprintf("Deployment %s pod template is missing cost-centre", [input.metadata.name])
}

# ---------------------------------------------------------------------------
# No privileged containers in workload namespaces.
# ---------------------------------------------------------------------------
deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  container.securityContext.privileged == true
  msg := sprintf("Deployment %s runs a privileged container", [input.metadata.name])
}

# ---------------------------------------------------------------------------
# No Secret objects with inline data anywhere in apps/.
# ---------------------------------------------------------------------------
deny[msg] {
  input.kind == "Secret"
  input.data
  msg := sprintf("Secret %s has inline data — use an ExternalSecret", [input.metadata.name])
}

deny[msg] {
  input.kind == "Secret"
  input.stringData
  msg := sprintf("Secret %s has inline stringData — use an ExternalSecret", [input.metadata.name])
}
