#!/usr/bin/env bash
# Grant or revoke the temporary writer role for one ring (the resource group of the vault whose policy you will change). The role definition is created with that
# scope as its only assignable scope and removed again on revoke.
# Usage: scripts/ring-role.sh grant|revoke <subscription-id> <ring-resource-group> <automation-identity-principal-id>
# Needs: Owner or User Access Administrator on the ring resource group (roleDefinitions/write + roleAssignments/write).
set -euo pipefail
ACTION=${1:?grant|revoke}; SUB=${2:?subscription id}; RG=${3:?ring resource group}; PRINCIPAL=${4:?principal id of the Automation Account identity}
SCOPE="/subscriptions/$SUB/resourceGroups/$RG"; ROLE="Azure Backup Smart Tiering Policy Remediator"; TEMPLATE="$(dirname "$0")/../infra/rbac/policy-remediator-role.template.json"
case "$ACTION" in
  grant)
    RENDERED=$(mktemp); sed "s#<subscription-id>#$SUB#; s#<ring-resource-group>#$RG#; s#REPLACE_WITH_SUBSCRIPTION_ID#$SUB#" "$TEMPLATE" > "$RENDERED"
    if az role definition list --custom-role-only true --scope "$SCOPE" --query "[?roleName=='$ROLE'].roleName" -o tsv | grep -q .; then echo "role definition exists"; else
      az role definition create --role-definition @"$RENDERED" -o none && echo "role definition created (assignable scope: $SCOPE)"; fi
    rm -f "$RENDERED"
    az role assignment create --assignee-object-id "$PRINCIPAL" --assignee-principal-type ServicePrincipal --role "$ROLE" --scope "$SCOPE" -o none && echo "assigned to $PRINCIPAL at $SCOPE"
    echo "RBAC can take several minutes to propagate; a write refused with 403 before then is reported as Forbidden and nothing is changed." ;;
  revoke)
    az role assignment delete --assignee "$PRINCIPAL" --role "$ROLE" --scope "$SCOPE" -o none 2>/dev/null && echo "assignment removed" || echo "no assignment"
    az role definition delete --name "$ROLE" --scope "$SCOPE" -o none 2>/dev/null && echo "role definition removed" || echo "no role definition"
    echo "remaining assignments at $SCOPE:"; az role assignment list --scope "$SCOPE" --query '[].{principal:principalId, role:roleDefinitionName}' -o tsv | sed 's/^/  /' ;;
  *) echo "usage: $0 grant|revoke <subscription-id> <ring-resource-group> <principal-id>" >&2; exit 2 ;;
esac
