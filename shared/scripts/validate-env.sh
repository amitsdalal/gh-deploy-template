#!/usr/bin/env bash
#
# validate-env.sh -- check an env file for the defects that break deployments.
#
#   ./validate-env.sh path/to/.env
#
# Every rule here comes from a real failure. The application's own dotenv
# loader is forgiving; Docker, docker compose and the shell are not, so a file
# can build successfully and then fail at deploy time.
#
# Prints line numbers and key names only -- never values -- so it is safe to
# run in CI logs.
#
set -uo pipefail
F="${1:-.env}"
[ -f "$F" ] || { echo "ERROR: no such file: $F" >&2; exit 2; }

fail=0
report() { printf '  line %-4s %-34s %s\n' "$1" "$2" "$3"; fail=1; }

lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno+1))
  case "$line" in *$'\r'*) report "$lineno" "-" "CRLF line ending (run: dos2unix)";; esac
  line="${line%$'\r'}"
  [ -z "${line// }" ] && continue
  case "$line" in \#*) continue;; esac
  case "$line" in
    *=*) : ;;
    *) report "$lineno" "-" "no '=' on a non-comment line"; continue ;;
  esac
  key="${line%%=*}"; val="${line#*=}"
  [ "$key" != "${key// }" ] && report "$lineno" "${key// }" "space around '=' -- write KEY=value"
  k="${key// }"
  case "$k" in
    [A-Za-z_]*) : ;;
    *) report "$lineno" "$k" "key does not start with a letter or underscore" ;;
  esac
  trimmed="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ "$val" != "$trimmed" ] && report "$lineno" "$k" "leading/trailing space in value"
  sq="$(printf '%s' "$trimmed" | tr -cd "'" | wc -c | tr -d ' ')"
  dq="$(printf '%s' "$trimmed" | tr -cd '"' | wc -c | tr -d ' ')"
  [ $((sq % 2)) -ne 0 ] && report "$lineno" "$k" "unbalanced single quote -- Docker rejects the whole file"
  [ $((dq % 2)) -ne 0 ] && report "$lineno" "$k" "unbalanced double quote -- Docker rejects the whole file"
done < "$F"

if [ "$fail" -eq 0 ]; then
  echo "OK: $F is clean ($(grep -cE '^[[:space:]]*[A-Za-z_]' "$F") keys)"
else
  echo
  echo "FAILED: fix the lines above before deploying." >&2
  exit 1
fi
