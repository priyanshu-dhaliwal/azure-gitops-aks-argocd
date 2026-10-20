# Cost model — GitOps AKS Platform

Estimates in **INR/month**, `centralindia`, list prices at time of writing.

## Prod

| Resource | Config | Monthly |
|---|---|---|
| AKS control plane | Free tier (uptime SLA: +₹3,000) | ₹0 |
| System node pool | 3 × Standard_D4s_v5 (4 vCPU, 16 GB), zone-redundant | ~₹42,000 |
| Workload node pool | 2–10 × Standard_D4s_v5 (autoscale) | ~₹28,000 at 2 nodes |
| Azure Firewall | Standard, forced egress | ~₹14,000 |
| ACR | Premium, zone redundant | ~₹4,000 |
| Key Vault | Standard, private endpoint | ~₹500 |
| Log Analytics | Container Insights, ~20 GB/mo | ~₹9,000 |
| Ingress public IP | Standard | ~₹300 |
| Managed disks (ephemeral OS, no charge) | — | ₹0 |
| **Total** | | **~₹97,800** |

## Dev

| Resource | Config | Monthly |
|---|---|---|
| AKS control plane | Free | ₹0 |
| System node pool | 1–2 × Standard_D2s_v5 | ~₹8,000 |
| Workload node pool | 1–3 × Standard_D2s_v5 **spot** | ~₹2,500 |
| Azure Firewall | Standard | ~₹14,000 |
| ACR | Premium | ~₹4,000 |
| Log Analytics | ~5 GB/mo | ~₹2,500 |
| Key Vault + IPs | — | ~₹800 |
| **Total** | | **~₹31,800** |

## Where the money goes

**Compute is 70% of the bill.** The three levers, in order of impact:

1. **Spot node pools for the workload tier.** ~70% cheaper. The trade-off is
   eviction with a 30-second warning; acceptable for stateless workers, not for
   anything holding a lease. Already applied in dev.
2. **Right-size the system pool.** `only_critical_addons_enabled = true` keeps
   workloads off it, which means it can be small. Do not let it grow to absorb
   workloads — that is how a 3-node system pool becomes a 6-node one.
3. **Cluster autoscaler + KEDA.** The workload pool scales to 2 at night if the
   HPA/KEDA scaling rules are written. Costs nothing to configure, saves ~40% of
   the workload compute.

**Azure Firewall is 14% and is the hardest to remove.** It is what makes egress
visible and forced. Alternatives: NAT Gateway (~₹2,500/mo, no inspection), or
egress through the AKS load balancer (no inspection, no FQDN control). The
firewall is the price of GitOps property 7 being real rather than aspirational.

## Cost of the failure modes this prevents

| Failure | Cost without GitOps | Cost with it |
|---|---|---|
| A manual hotfix silently reverted by the next deploy | hours of debugging, one incident | 0 — manual changes are corrected in 3 min, by design |
| A bad image tag reaching every pod | full outage until rollback (~₹8,000/min at 10k rpm) | stopped at 10% of traffic |
| A privileged pod on a node | potential node compromise | blocked at admission |
| A secret committed to Git | rotation + audit + disclosure | blocked in CI |

The platform costs ~₹98,000/month. One avoided full outage pays for it for a
year.
