#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUIDE="$ROOT/docs/replicate-in-azure.md"
FUNCTION_TEXT="$(awk '
  /^revoke_writer_on_exit\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "$GUIDE")"

test -n "$FUNCTION_TEXT"
grep -q '^  trap - EXIT$' <<< "$FUNCTION_TEXT"
grep -q '^      exit 1$' <<< "$FUNCTION_TEXT"
grep -q '^  exit "\$original_status"$' <<< "$FUNCTION_TEXT"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/scripts"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'exit "${FAKE_REVOKE_STATUS:?}"' \
  > "$TEST_DIR/scripts/ring-role.sh"
chmod 700 "$TEST_DIR/scripts/ring-role.sh"

{
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'AUTOMATION_DIR="$1"' \
    'ORIGINAL_STATUS="$2"' \
    'SUB=test-subscription' \
    'RG=test-resource-group' \
    'PRINCIPAL=test-principal' \
    'WRITER_GRANTED=true'
  printf '%s\n' "$FUNCTION_TEXT"
  printf '%s\n' \
    'trap revoke_writer_on_exit EXIT' \
    'exit "$ORIGINAL_STATUS"'
} > "$TEST_DIR/harness.sh"
chmod 700 "$TEST_DIR/harness.sh"

run_case() {
  local revoke_status="$1" original_status="$2" expected_status="$3" actual_status
  set +e
  FAKE_REVOKE_STATUS="$revoke_status" bash "$TEST_DIR/harness.sh" \
    "$TEST_DIR" "$original_status" > /dev/null 2>&1
  actual_status=$?
  set -e
  if [ "$actual_status" -ne "$expected_status" ]; then
    printf 'Trap regression failed: revoke=%s original=%s expected=%s actual=%s\n' \
      "$revoke_status" "$original_status" "$expected_status" "$actual_status" >&2
    return 1
  fi
}

# A failed revocation must turn an otherwise successful shell into a failure.
run_case 7 0 1
# A successful revocation must preserve the failure that originally triggered EXIT.
run_case 0 23 23

printf 'Replication-guide writer EXIT trap regression passed.\n'
