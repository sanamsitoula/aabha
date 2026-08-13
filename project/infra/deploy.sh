#!/usr/bin/env bash
# deploy.sh — deploy the Aabha multi-tier reference architecture to Azure.
#
# Prerequisites:
#   - az CLI installed and logged in (az login)
#   - Bicep CLI (comes bundled with recent az CLI: az bicep install)
#   - An SSH key pair: ssh-keygen -t rsa -b 4096 -f ~/.ssh/aabha_vmss
#
# Usage:
#   cp main.parameters.example.json main.parameters.json
#   # edit main.parameters.json with real values (passwords, SSH key)
#   ./deploy.sh

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aabha-dev}"
LOCATION="${LOCATION:-eastus}"
PARAMS_FILE="${PARAMS_FILE:-main.parameters.json}"

if [ ! -f "$PARAMS_FILE" ]; then
  echo "Missing $PARAMS_FILE. Copy main.parameters.example.json to $PARAMS_FILE and fill in real values first."
  exit 1
fi

echo "==> Creating resource group $RESOURCE_GROUP in $LOCATION"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

echo "==> Validating template"
az deployment group validate \
  --resource-group "$RESOURCE_GROUP" \
  --template-file main.bicep \
  --parameters "@$PARAMS_FILE"

echo "==> Deploying (this provisions VNet, NSGs, NAT Gateway, App Gateway, VMSS, autoscale, and MySQL — expect 20-30 minutes)"
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file main.bicep \
  --parameters "@$PARAMS_FILE"

echo "==> Deployment outputs"
az deployment group show \
  --resource-group "$RESOURCE_GROUP" \
  --name main \
  --query properties.outputs
