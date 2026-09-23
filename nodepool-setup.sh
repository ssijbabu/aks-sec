#!/usr/bin/env bash
# Node pool layout so that no application pod runs on a node before auditd is configured.
#
#  - System pool: CriticalAddonsOnly taint keeps app pods off it. NOT given the startup
#    taint: CoreDNS, konnectivity, metrics-server and the Flux/Argo controllers that deploy
#    the DaemonSet must be able to schedule, or you deadlock.
#  - User pools: created with a node *initialization* taint. AKS applies it once at node
#    creation and doesn't re-add it, so the DaemonSet can remove it.
#    (A regular --node-taints taint would be put back by AKS reconciliation.)
set -euo pipefail

RG="<resource-group>"
CLUSTER="<cluster-name>"
TAINT="startup-taint.cluster-autoscaler.kubernetes.io/auditd-not-ready=true:NoSchedule"

# System pool: only critical add-ons
az aks nodepool update -g "$RG" --cluster-name "$CLUSTER" -n systempool \
  --node-taints "CriticalAddonsOnly=true:NoSchedule"

# New user pool
az aks nodepool add -g "$RG" --cluster-name "$CLUSTER" -n userpool1 \
  --os-sku AzureLinux --mode User \
  --enable-cluster-autoscaler --min-count 2 --max-count 10 \
  --node-init-taints "$TAINT"

# Existing user pool: applies to nodes created from now on.
# az aks nodepool update -g "$RG" --cluster-name "$CLUSTER" -n <existing-pool> \
#   --node-init-taints "$TAINT"
