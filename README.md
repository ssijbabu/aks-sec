# AKS node auditd: persistent configuration and log collection

Keeps a consistent auditd configuration on every AKS node (Azure Linux) and ships the audit logs to Log Analytics. It also guarantees that **no application pod runs on a node until auditd is configured**. All of this happens automatically when the cluster autoscales, upgrades, or reimages nodes. Nothing has to be done by hand on individual nodes.

## The problem

AKS nodes are rebuilt from a Microsoft-managed image whenever they scale out, upgrade, or get reimaged. Changes made by hand (SSH, editing the VM scale set, custom script extensions) are lost, and AKS doesn't support custom node images or configuring auditd through `linuxOSConfig`.

## The approach

Instead of changing the node image, a **privileged DaemonSet** configures each node after it boots. Kubernetes places a DaemonSet pod on every node, including new ones, so the configuration follows the cluster as it changes.

| Concern | Mechanism |
|---|---|
| Apply audit rules to every node | `auditd-config` DaemonSet writes `/etc/audit/rules.d/90-org-*.rules` and runs `augenrules --load` |
| Keep rules applied (drift, rule changes) | The DaemonSet checks every 5 min and reapplies if the ConfigMap changed or the rules were flushed |
| Collect logs | `fluent-bit-audit` DaemonSet tails `/var/log/audit/audit.log` and sends it to Log Analytics through the Logs Ingestion API |
| Keep apps off unconfigured nodes | Node pool **initialization taint**, removed by the DaemonSet once rules are loaded |
| Deploy this before any apps | Flux `dependsOn`, so `apps` waits for `node-config` to be healthy |

## How a new node comes up

```
Pending pods → cluster autoscaler adds a node
        │
        ▼
AKS creates the node WITH the startup taint          (node pool setting, automatic)
        │
        ▼
Scheduler: app pods can't tolerate the taint, so they keep waiting
           auditd-config + fluent-bit tolerate it, so they start
        │
        ▼
auditd-config: install/start auditd if needed → write rules → augenrules --load
               → check that rules are loaded → pod becomes Ready
        │
        ▼
auditd-config removes the taint from its own node
        │
        ▼
App pods are scheduled onto the node
```

| Event | What happens |
|---|---|
| Scale-up | New node goes through the flow above |
| Scale-down | Node and everything on it is removed; nothing to do |
| Upgrade / node image update | Replacement nodes are created with the taint, same flow |
| Node reboot | Taint is already gone; rules persist on disk and are loaded at boot; DaemonSet re-checks within 5 min |
| Rule change | Edit the ConfigMap; running pods pick it up within ~1–6 min, no restart needed |

### Why these particular settings

- **`--node-init-taints`, not `--node-taints`.** AKS applies initialization taints once, when the node is created, and doesn't put them back. Regular node taints are continually reapplied by AKS, so they would reappear after the DaemonSet removed them.
- **The `startup-taint.cluster-autoscaler.kubernetes.io/` prefix.** The cluster autoscaler ignores taints with this prefix when deciding whether a new node would fit pending pods. Without it, the autoscaler might decide new nodes are useless and never scale up.
- **No startup taint on the system pool.** CoreDNS, konnectivity, and the Flux or Argo controllers that deploy this DaemonSet must be able to run there. Tainting it would deadlock the cluster. The system pool gets `CriticalAddonsOnly=true:NoSchedule` instead, so app pods never land there. The DaemonSet still configures auditd on system nodes.

## Files

| File | Purpose |
|---|---|
| `00-namespace.yaml` | `node-config` namespace, allowed to run privileged pods |
| `10-auditd-config.yaml` | Audit rules ConfigMap, RBAC, `auditd-config` DaemonSet, and its script |
| `20-fluent-bit-audit.yaml` | Fluent Bit Secret/ConfigMap/DaemonSet that ships `audit.log` to Log Analytics |
| `25-taint-guard-policy.yaml` | *(Optional, K8s ≥ 1.30)* ValidatingAdmissionPolicy: the DaemonSet may only remove its own taint on its own node |
| `30-flux-ordering.yaml` | Flux Kustomizations: `apps` depends on `node-config` |
| `Dockerfile` | Image for `auditd-config` (Azure Linux core + `curl` + `jq`) |
| `la-setup.sh` | One-time setup: Log Analytics custom table `AKSNodeAudit_CL`, DCE, DCR, ingestion identity |
| `nodepool-setup.sh` | One-time setup: system pool taint and user pool initialization taint |

## Prerequisites

- AKS with **Azure Linux** node pools
- Kubernetes ≥ 1.30 if you use `25-taint-guard-policy.yaml`
- Azure CLI new enough to support `--node-init-taints` (or the `aks-preview` extension)
- An Azure Container Registry attached to the cluster
- A Log Analytics workspace
- Flux (the AKS GitOps extension) or Argo CD for deployment ordering
- Nodes can reach `packages.microsoft.com` **only if** the `audit` package isn't already on the node image

## Setup

Do these steps once per cluster. Ideally put them in IaC and GitOps.

### 1. Check a node's current state

```bash
kubectl debug node/<node> -it --image=mcr.microsoft.com/azurelinux/base/core:3.0 -- \
  chroot /host bash -c 'rpm -q audit; systemctl is-active auditd; auditctl -s; ls /etc/audit/rules.d/'
```

- If `rules.d` already has baseline rules, leave them; yours are added alongside.
- If `auditctl -s` shows `enabled 2`, the rules are immutable until reboot and can't be changed at runtime.

### 2. Build and push the image

```bash
az acr build -r <your-acr> -t node-config/auditd-config:1.0 .
```

Then update the `image:` line in `10-auditd-config.yaml`.

### 3. Create the Log Analytics resources

Fill in the variables in `la-setup.sh`, run it, and put its output into the `fluent-bit-la` Secret in `20-fluent-bit-audit.yaml`. Keep the client secret in Key Vault (for example through the Secrets Store CSI driver), not in git. Also set `CLUSTER_NAME` in the same file.

### 4. Allow the privileged namespace

If you use the Azure Policy add-on or Gatekeeper, exempt the `node-config` namespace. The pods need `privileged`, `hostPID`, `hostNetwork`, and `hostPath`.

### 5. Deploy

Commit `00-`, `10-`, `20-`, `25-` to the `node-config` path and `30-flux-ordering.yaml` to your Flux config. Alternatively, apply them directly:

```bash
kubectl apply -f 00-namespace.yaml -f 10-auditd-config.yaml -f 20-fluent-bit-audit.yaml -f 25-taint-guard-policy.yaml
```

### 6. Configure node pools

Fill in the variables in `nodepool-setup.sh` and run it. For Bicep/ARM, the equivalent agent pool property is `nodeInitializationTaints`.

The init taint only applies to nodes created **after** it's set. To also gate existing nodes, replace them:

```bash
az aks nodepool upgrade -g <rg> --cluster-name <cluster> -n <pool> --node-image-only
```

## Verify

Watch taints while scaling a user pool up by one node:

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints[*].key -w
```

The new node should appear with `startup-taint.cluster-autoscaler.kubernetes.io/auditd-not-ready`, and the taint should disappear a few seconds after `auditd-config` is Ready on it.

```bash
kubectl -n node-config get ds
```

```bash
kubectl -n node-config logs ds/auditd-config
```

Check the loaded rules on a node:

```bash
kubectl debug node/<node> -it --image=mcr.microsoft.com/azurelinux/base/core:3.0 -- chroot /host auditctl -l
```

Query the logs in Log Analytics:

```kusto
AKSNodeAudit_CL
| where TimeGenerated > ago(1h)
| where RawData has "key=\"identity\"" or RawData has "key=\"root_cmd\""
| project TimeGenerated, Cluster, Computer, AuditType, RawData
| order by TimeGenerated desc
```

## Operations

### Changing rules

Edit the `auditd-rules` ConfigMap in `10-auditd-config.yaml`:

- Each `*.rules` key becomes `/etc/audit/rules.d/90-org-<key>` on every node.
- Removing a key removes the corresponding file from the nodes.
- `auditd.conf.overrides` sets `key = value` pairs in `/etc/audit/auditd.conf`. The defaults cap audit logs at 5 × 50 MB and rotate them.

Kubelet syncs ConfigMap changes into running pods within about a minute, and the next check (at most 5 min later) applies them. No rollout is needed.

### Rule volume

Keep `execve` rules narrow. The shipped rule only records commands run as root by a real logged-in user (`auid>=1000`). Recording every process start from every container would produce a very large volume of logs on busy nodes. Use `-b` (backlog) and `-r` (rate limit) in `base.rules`, and test volume on a non-production pool first.

Don't add `-e 2` (immutable rules) until the rule set is stable. Once it's set, rule changes need a reboot.

### Alerting

Set up alerts for:

- **Nodes stuck with the startup taint** for more than ~10 minutes: auditd couldn't be configured, so apps won't schedule there.
- **`auditd-config` or `fluent-bit-audit` pods not Ready.**
- **No `AKSNodeAudit_CL` data** from a node or cluster for more than N minutes.

## Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| Node never loses the taint | auditd install/start failed, `augenrules` failed, or the taint PATCH was denied | `kubectl -n node-config logs <auditd-config pod on that node>` |
| `ERROR: audit rules are immutable` | Node has `-e 2` loaded | Remove `-e 2` from rules; the node needs a reboot or reimage |
| `could not install audit` | No egress to `packages.microsoft.com` | Allow it in your firewall, or confirm the package is in the node image |
| `failed to remove startup taint` | RBAC missing, or the admission policy denied the patch | `kubectl auth can-i patch nodes --as=system:serviceaccount:node-config:auditd-config` |
| DaemonSet pods not created | Azure Policy / Gatekeeper / Pod Security blocking privileged pods | Namespace labels and policy exemptions |
| No logs in Log Analytics | Wrong Secret values, missing `Monitoring Metrics Publisher` role on the DCR, or DCR stream/column mismatch | `kubectl -n node-config logs ds/fluent-bit-audit` |
| Autoscaler doesn't add nodes for pending pods | Taint doesn't use the `startup-taint.cluster-autoscaler.kubernetes.io/` prefix | `az aks nodepool show ... --query nodeInitializationTaints` |

## Security notes

- `auditd-config` is privileged and has host access; treat the `node-config` namespace as part of the node's trust boundary. Limit who can create or modify resources in it.
- Its ServiceAccount can `get`/`patch` nodes. `25-taint-guard-policy.yaml` narrows that to removing only its own taint, only on its own node.
- `fluent-bit-audit` runs as root to read `audit.log` (mode 0600), but isn't privileged and has read-only access to `/var/log/audit`.

## Alternatives considered

| Option | Why not used here |
|---|---|
| SSH / manual node changes | Lost on every scale-out, upgrade, or reimage |
| VMSS custom script extension | Not supported on AKS-managed scale sets; overwritten |
| Custom node image | Not supported by AKS |
| AKS custom node config (`linuxOSConfig`) | Only covers sysctls, transparent huge pages, and swap; no auditd |
| eBPF runtime sensors (Defender for Containers, Falco, Tetragon) | Good for Kubernetes-aware threat detection and often used **alongside** this. They don't satisfy requirements that explicitly call for auditd. |
