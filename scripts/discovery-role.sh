#!/usr/bin/env bash
# Grant or revoke the read-only discovery role for one resource-group ring.
# Usage: scripts/discovery-role.sh grant|revoke <subscription-id> <ring-resource-group> <automation-identity-principal-id>
# Needs: Owner or User Access Administrator on the ring resource group to create/delete the custom
# role definition and role assignment. The role name gets a deterministic scope suffix so multiple
# isolated rings in the same tenant do not collide.
set -euo pipefail
ACTION=${1:?grant|revoke}; SUB=${2:?subscription id}; RG=${3:?ring resource group}; PRINCIPAL=${4:?principal id of the Automation Account identity}
SCOPE="/subscriptions/$SUB/resourceGroups/$RG"; ROLE_SUFFIX=$(printf '%s' "$SCOPE" | sha256sum | cut -c1-12); ROLE="Azure Backup Smart Tiering Discovery Reader - $ROLE_SUFFIX"; TEMPLATE="$(dirname "$0")/../infra/rbac/discovery-reader-rg-role.template.json"
case "$ACTION" in
  grant)
    RENDERED=$(mktemp)
    trap 'rm -f "$RENDERED"' EXIT
    sed "s#<subscription-id>#$SUB#; s#<ring-resource-group>#$RG#; s#<role-suffix>#$ROLE_SUFFIX#" "$TEMPLATE" > "$RENDERED"
    if az role definition list --subscription "$SUB" --custom-role-only true --scope "$SCOPE" --query "[?roleName=='$ROLE'].roleName" -o tsv | grep -q .; then
      echo "role definition exists"
    else
      az role definition create --subscription "$SUB" --role-definition @"$RENDERED" -o none
      echo "RG-scoped discovery role definition created"
    fi
    if az role assignment list --subscription "$SUB" --assignee-object-id "$PRINCIPAL" --fill-principal-name false --role "$ROLE" --scope "$SCOPE" --query 'length(@)' -o tsv | grep -Eq '^[1-9][0-9]*$'; then
      echo "role assignment exists"
    else
      az role assignment create --subscription "$SUB" --assignee-object-id "$PRINCIPAL" --assignee-principal-type ServicePrincipal --role "$ROLE" --scope "$SCOPE" -o none
      echo "RG-scoped discovery role assignment created"
    fi
    echo "RBAC can take several minutes to propagate; a job started too early fails closed with 403."
    ;;
  revoke)
    ROLE_ID=$(az role definition list --subscription "$SUB" --custom-role-only true --scope "$SCOPE" --query "[?roleName=='$ROLE'] | [0].name" -o tsv)
    if [ -z "$ROLE_ID" ]; then
      echo "no role definition"
      exit 0
    fi
    if az role assignment list --subscription "$SUB" --assignee-object-id "$PRINCIPAL" --fill-principal-name false --role "$ROLE_ID" --scope "$SCOPE" --query 'length(@)' -o tsv | grep -Eq '^[1-9][0-9]*$'; then
      az role assignment delete --subscription "$SUB" --assignee-object-id "$PRINCIPAL" --role "$ROLE_ID" --scope "$SCOPE" -o none
      echo "assignment removed"
    else
      echo "no assignment"
    fi
    for _ in $(seq 1 24); do
      [ "$(az role assignment list --subscription "$SUB" --assignee-object-id "$PRINCIPAL" --fill-principal-name false --role "$ROLE_ID" --scope "$SCOPE" --query 'length(@)' -o tsv)" = "0" ] && break
      sleep 5
    done
    test "$(az role assignment list --subscription "$SUB" --assignee-object-id "$PRINCIPAL" --fill-principal-name false --role "$ROLE_ID" --scope "$SCOPE" --query 'length(@)' -o tsv)" = "0"
    if az role definition list --subscription "$SUB" --custom-role-only true --scope "$SCOPE" --query "[?roleName=='$ROLE'].roleName" -o tsv | grep -q .; then
      for _ in $(seq 1 24); do
        if az role definition delete --subscription "$SUB" --name "$ROLE_ID" --scope "$SCOPE" -o none 2>/dev/null; then
          break
        fi
        sleep 5
      done
      echo "role definition deletion requested"
    else
      echo "no role definition"
    fi
    for _ in $(seq 1 24); do
      [ -z "$(az role definition list --subscription "$SUB" --custom-role-only true --scope "$SCOPE" --query "[?roleName=='$ROLE'].roleName" -o tsv)" ] && break
      sleep 5
    done
    test -z "$(az role definition list --subscription "$SUB" --custom-role-only true --scope "$SCOPE" --query "[?roleName=='$ROLE'].roleName" -o tsv)"
    ;;
  *) echo "usage: $0 grant|revoke <subscription-id> <ring-resource-group> <principal-id>" >&2; exit 2 ;;
esac
