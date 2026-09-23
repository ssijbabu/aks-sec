#!/usr/bin/env bash
# One-time setup: custom table + DCE + DCR in Log Analytics for node audit logs,
# and an app registration that Fluent Bit uses to send data.
set -euo pipefail

RG="<resource-group>"
LOCATION="<region>"
WORKSPACE="<log-analytics-workspace-name>"
DCE_NAME="dce-aks-node-audit"
DCR_NAME="dcr-aks-node-audit"
TABLE="AKSNodeAudit_CL"

WS_ID=$(az monitor log-analytics workspace show -g "$RG" -n "$WORKSPACE" --query id -o tsv)

# 1. Custom table
az monitor log-analytics workspace table create -g "$RG" --workspace-name "$WORKSPACE" \
  --name "$TABLE" --retention-time 90 \
  --columns TimeGenerated=datetime Computer=string Cluster=string \
            AuditType=string AuditSerial=string RawData=string

# 2. Data collection endpoint
az monitor data-collection endpoint create -g "$RG" -l "$LOCATION" \
  --name "$DCE_NAME" --public-network-access Enabled
DCE_ID=$(az monitor data-collection endpoint show -g "$RG" -n "$DCE_NAME" --query id -o tsv)
DCE_URL=$(az monitor data-collection endpoint show -g "$RG" -n "$DCE_NAME" --query logsIngestion.endpoint -o tsv)

# 3. Data collection rule
cat > /tmp/dcr-aks-node-audit.json <<EOF
{
  "location": "$LOCATION",
  "properties": {
    "dataCollectionEndpointId": "$DCE_ID",
    "streamDeclarations": {
      "Custom-$TABLE": {
        "columns": [
          { "name": "TimeGenerated", "type": "datetime" },
          { "name": "Computer",      "type": "string" },
          { "name": "Cluster",       "type": "string" },
          { "name": "AuditType",     "type": "string" },
          { "name": "AuditSerial",   "type": "string" },
          { "name": "RawData",       "type": "string" }
        ]
      }
    },
    "destinations": {
      "logAnalytics": [ { "workspaceResourceId": "$WS_ID", "name": "la" } ]
    },
    "dataFlows": [
      {
        "streams": [ "Custom-$TABLE" ],
        "destinations": [ "la" ],
        "transformKql": "source",
        "outputStream": "Custom-$TABLE"
      }
    ]
  }
}
EOF
az monitor data-collection rule create -g "$RG" -n "$DCR_NAME" -l "$LOCATION" \
  --rule-file /tmp/dcr-aks-node-audit.json
DCR_ID=$(az monitor data-collection rule show -g "$RG" -n "$DCR_NAME" --query id -o tsv)
DCR_IMMUTABLE_ID=$(az monitor data-collection rule show -g "$RG" -n "$DCR_NAME" --query immutableId -o tsv)

# 4. Identity for Fluent Bit, allowed to publish to this DCR only
SP=$(az ad sp create-for-rbac --name "sp-aks-node-audit-ingest" --skip-assignment -o json)
CLIENT_ID=$(echo "$SP" | jq -r .appId)
az role assignment create --assignee "$CLIENT_ID" \
  --role "Monitoring Metrics Publisher" --scope "$DCR_ID"

echo
echo "Put these into the fluent-bit-la Secret (20-fluent-bit-audit.yaml):"
echo "  TENANT_ID     = $(echo "$SP" | jq -r .tenant)"
echo "  CLIENT_ID     = $CLIENT_ID"
echo "  CLIENT_SECRET = (password from the create-for-rbac output; store it in Key Vault)"
echo "  DCE_URL       = $DCE_URL"
echo "  DCR_ID        = $DCR_IMMUTABLE_ID"
