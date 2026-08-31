#!/usr/bin/env bash
# Grant or revoke the read-only discovery role for one resource-group ring.
# Usage: scripts/discovery-role.sh grant|revoke <subscription-id> <ring-resource-group> <automation-identity-principal-id>
# Needs: Owner or User Access Administrator on the ring resource group to create/delete the custom
# role definition and role assignment. The role name gets a deterministic scope suffix so multiple
# isolated rings in the same tenant do not collide.
set -euo pipefail
umask 077
ACTION=${1:?grant|revoke}; SUB=${2:?subscription id}; RG=${3:?ring resource group}; PRINCIPAL=${4:?principal id of the Automation Account identity}
SCOPE="/subscriptions/$SUB/resourceGroups/$RG"; ROLE_SUFFIX=$(printf '%s' "$SCOPE" | sha256sum | cut -c1-12); ROLE="Azure Backup Smart Tiering Discovery Reader - $ROLE_SUFFIX"; TEMPLATE="$(dirname "$0")/../infra/rbac/discovery-reader-rg-role.template.json"
case "$ACTION" in
  grant)
    RENDERED=$(mktemp)
    ACTUAL=$(mktemp)
    ASSIGNMENTS=$(mktemp)
    ROLE_RESULT=$(mktemp)
    ROLE_CREATED=false
    ROLE_ID=
    ASSIGNMENT_CREATED=false
    ASSIGNMENT_ID=

    role_matches_template() {
      jq -e --arg role "$ROLE" --arg scope "$SCOPE" --slurpfile expected "$RENDERED" '
        $expected[0] as $e
        | [.[] | select(((.roleName // "") | ascii_downcase) == ($role | ascii_downcase))] as $matches
        | ($matches | length) == 1
          and (($matches[0].assignableScopes // [] | map(ascii_downcase) | sort) == [($scope | ascii_downcase)])
          and (($matches[0].permissions // [] | length) == 1)
          and (($matches[0].permissions[0].actions // [] | map(ascii_downcase) | sort) == ($e.Actions | map(ascii_downcase) | sort))
          and (($matches[0].permissions[0].notActions // [] | map(ascii_downcase) | sort) == ($e.NotActions | map(ascii_downcase) | sort))
          and (($matches[0].permissions[0].dataActions // [] | map(ascii_downcase) | sort) == ($e.DataActions | map(ascii_downcase) | sort))
          and (($matches[0].permissions[0].notDataActions // [] | map(ascii_downcase) | sort) == ($e.NotDataActions | map(ascii_downcase) | sort))
      ' "$ACTUAL" >/dev/null
    }

    assignment_is_exactly_one() {
      if [ "$ASSIGNMENT_CREATED" = true ]; then
        jq -e --arg id "$ASSIGNMENT_ID" '
          length == 1
          and (((.[0].id // "") | ascii_downcase) == ($id | ascii_downcase))
        ' "$ASSIGNMENTS" >/dev/null
      else
        jq -e 'length == 1' "$ASSIGNMENTS" >/dev/null
      fi
    }

    cleanup_grant() {
      local original_status=$?
      local rollback_failed=false
      local deletion_accepted=false
      local removed=false
      trap - EXIT

      if [ "$original_status" -ne 0 ]; then
        set +e
        if [ "$ASSIGNMENT_CREATED" = true ] && [ -n "$ASSIGNMENT_ID" ]; then
          deletion_accepted=false
          removed=false
          for _ in $(seq 1 24); do
            if az role assignment delete --subscription "$SUB" --ids "$ASSIGNMENT_ID" -o none >/dev/null 2>&1; then
              deletion_accepted=true
            fi
            if [ "$deletion_accepted" = true ] \
              && az role assignment list --subscription "$SUB" --assignee-object-id "$PRINCIPAL" --fill-principal-name false --scope "$SCOPE" -o json > "$ASSIGNMENTS" 2>/dev/null \
              && jq -e --arg id "$ASSIGNMENT_ID" '[.[] | select(((.id // "") | ascii_downcase) == ($id | ascii_downcase))] | length == 0' "$ASSIGNMENTS" >/dev/null; then
              removed=true
              break
            fi
            sleep 5
          done
          if [ "$removed" != true ]; then
            echo "grant rollback could not confirm removal of its role assignment" >&2
            rollback_failed=true
          fi
        fi

        if [ "$ROLE_CREATED" = true ]; then
          deletion_accepted=false
          removed=false
          if [ -z "$ROLE_ID" ]; then
            echo "grant rollback could not identify its role definition" >&2
            rollback_failed=true
          else
            for _ in $(seq 1 24); do
              if az role definition delete --subscription "$SUB" --name "$ROLE_ID" --scope "$SCOPE" -o none >/dev/null 2>&1; then
                deletion_accepted=true
              fi
              if [ "$deletion_accepted" = true ] \
                && az role definition list --subscription "$SUB" --custom-role-only true --scope "$SCOPE" -o json > "$ACTUAL" 2>/dev/null \
                && jq -e --arg id "$ROLE_ID" '[.[] | select(((.name // "") | ascii_downcase) == ($id | ascii_downcase))] | length == 0' "$ACTUAL" >/dev/null; then
                removed=true
                break
              fi
              sleep 5
            done
            if [ "$removed" != true ]; then
              echo "grant rollback could not confirm removal of its role definition" >&2
              rollback_failed=true
            fi
          fi
        fi
        set -e
      fi

      rm -f "$RENDERED" "$ACTUAL" "$ASSIGNMENTS" "$ROLE_RESULT"
      if [ "$rollback_failed" = true ]; then
        exit 1
      fi
      exit "$original_status"
    }
    trap cleanup_grant EXIT

    sed "s#<subscription-id>#$SUB#; s#<ring-resource-group>#$RG#; s#<role-suffix>#$ROLE_SUFFIX#" "$TEMPLATE" > "$RENDERED"

    if ! az role definition list --subscription "$SUB" --custom-role-only true --scope "$SCOPE" -o json > "$ACTUAL" 2>/dev/null; then
      echo "unable to inspect the discovery role definition" >&2
      exit 1
    fi
    ROLE_COUNT=$(jq -r --arg role "$ROLE" '[.[] | select(((.roleName // "") | ascii_downcase) == ($role | ascii_downcase))] | length' "$ACTUAL")
    case "$ROLE_COUNT" in
      0)
        if ! az role definition create --subscription "$SUB" --role-definition @"$RENDERED" -o json > "$ROLE_RESULT" 2>/dev/null; then
          echo "unable to create the RG-scoped discovery role definition" >&2
          exit 1
        fi
        ROLE_CREATED=true
        ROLE_ID=$(jq -r '.name // empty' "$ROLE_RESULT")
        if [ -z "$ROLE_ID" ]; then
          echo "created discovery role definition returned no stable identifier" >&2
          exit 1
        fi
        ROLE_READY=false
        for _ in $(seq 1 24); do
          if az role definition list --subscription "$SUB" --custom-role-only true --scope "$SCOPE" -o json > "$ACTUAL" 2>/dev/null \
            && role_matches_template; then
            ROLE_READY=true
            break
          fi
          sleep 5
        done
        if [ "$ROLE_READY" != true ]; then
          echo "created discovery role definition did not become visible with the expected shape" >&2
          exit 1
        fi
        echo "RG-scoped discovery role definition created"
        ;;
      1)
        if ! role_matches_template; then
          echo "existing discovery role does not match the RG-only template" >&2
          exit 1
        fi
        echo "role definition exists"
        ;;
      *)
        echo "discovery role definition name is ambiguous" >&2
        exit 1
        ;;
    esac

    ASSIGNMENT_LIST_READY=false
    for _ in $(seq 1 24); do
      if az role assignment list --subscription "$SUB" --assignee-object-id "$PRINCIPAL" --fill-principal-name false --role "$ROLE" --scope "$SCOPE" -o json > "$ASSIGNMENTS" 2>/dev/null; then
        ASSIGNMENT_LIST_READY=true
        break
      fi
      sleep 5
    done
    if [ "$ASSIGNMENT_LIST_READY" != true ]; then
      echo "unable to inspect the discovery role assignment" >&2
      exit 1
    fi
    ASSIGNMENT_COUNT=$(jq -r 'length' "$ASSIGNMENTS")
    case "$ASSIGNMENT_COUNT" in
      0)
        if [ ! -r /proc/sys/kernel/random/uuid ]; then
          echo "unable to generate a role-assignment identifier" >&2
          exit 1
        fi
        ASSIGNMENT_NAME=$(</proc/sys/kernel/random/uuid)
        ASSIGNMENT_ID="$SCOPE/providers/Microsoft.Authorization/roleAssignments/$ASSIGNMENT_NAME"
        for _ in $(seq 1 24); do
          if az role assignment create --subscription "$SUB" --name "$ASSIGNMENT_NAME" --assignee-object-id "$PRINCIPAL" --assignee-principal-type ServicePrincipal --role "$ROLE" --scope "$SCOPE" -o none >/dev/null 2>&1; then
            ASSIGNMENT_CREATED=true
            break
          fi
          if az role assignment list --subscription "$SUB" --assignee-object-id "$PRINCIPAL" --fill-principal-name false --scope "$SCOPE" -o json > "$ASSIGNMENTS" 2>/dev/null \
            && jq -e --arg id "$ASSIGNMENT_ID" '[.[] | select(((.id // "") | ascii_downcase) == ($id | ascii_downcase))] | length == 1' "$ASSIGNMENTS" >/dev/null; then
            ASSIGNMENT_CREATED=true
            break
          fi
          sleep 5
        done
        if [ "$ASSIGNMENT_CREATED" != true ]; then
          echo "RG-scoped discovery role assignment did not become creatable" >&2
          exit 1
        fi
        echo "RG-scoped discovery role assignment created"
        ;;
      1)
        echo "role assignment exists"
        ;;
      *)
        echo "discovery role assignment is ambiguous" >&2
        exit 1
        ;;
    esac

    ASSIGNMENT_READY=false
    for _ in $(seq 1 24); do
      if az role assignment list --subscription "$SUB" --assignee-object-id "$PRINCIPAL" --fill-principal-name false --role "$ROLE" --scope "$SCOPE" -o json > "$ASSIGNMENTS" 2>/dev/null \
        && assignment_is_exactly_one; then
        ASSIGNMENT_READY=true
        break
      fi
      sleep 5
    done
    if [ "$ASSIGNMENT_READY" != true ]; then
      echo "discovery role assignment did not converge to exactly one match" >&2
      exit 1
    fi
    echo "RBAC can take several minutes to propagate; a job started too early fails closed with 403."
    trap - EXIT
    rm -f "$RENDERED" "$ACTUAL" "$ASSIGNMENTS" "$ROLE_RESULT"
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
