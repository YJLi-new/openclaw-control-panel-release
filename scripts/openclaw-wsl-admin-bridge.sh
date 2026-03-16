#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
openclaw_bin="${OPENCLAW_WSL_OPENCLAW_PATH:-/usr/local/bin/openclaw}"

wsl_to_windows_path() {
  local path="$1"
  if [[ "$path" =~ ^/mnt/([a-zA-Z])/(.*)$ ]]; then
    local drive="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[2]}"
    rest="${rest//\//\\}"
    printf '%s:\\%s' "${drive^^}" "$rest"
    return 0
  fi
  printf '%s' "$path"
}

bundle_windows_dir="$(wsl_to_windows_path "$script_dir")"
entry_script="${OPENCLAW_WIN_ADMIN_WSL_ENTRY:-${bundle_windows_dir}\\openclaw-win-admin-wsl-entry.ps1}"

resolve_control_ui_url() {
  local raw="${OPENCLAW_CONTROL_UI_URL_BASE:-${OPENCLAW_DASHBOARD_URL_BASE:-http://127.0.0.1:18790/}}"
  printf '%s' "$raw"
}

DASHBOARD_URL_BASE="$(resolve_control_ui_url)"
HEALTH_URL="${DASHBOARD_URL_BASE%/}/health"

open_windows_url() {
  local url="$1"
  if command -v powershell.exe >/dev/null 2>&1; then
    OPENCLAW_TARGET_URL="$url" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "[System.Diagnostics.Process]::Start($env:OPENCLAW_TARGET_URL) | Out-Null" >/dev/null 2>&1 && return 0
    OPENCLAW_TARGET_URL="$url" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'rundll32.exe' -ArgumentList 'url.dll,FileProtocolHandler', $env:OPENCLAW_TARGET_URL" >/dev/null 2>&1 && return 0
  fi
  if command -v rundll32.exe >/dev/null 2>&1; then
    rundll32.exe url.dll,FileProtocolHandler "$url" >/dev/null 2>&1 && return 0
  fi
  if command -v explorer.exe >/dev/null 2>&1; then
    explorer.exe "$url" >/dev/null 2>&1 && return 0
  fi
  return 1
}

extract_dashboard_url() {
  local output="$1"
  local line trimmed
  while IFS= read -r line; do
    trimmed="${line//$'\r'/}"
    if [[ "$trimmed" =~ ^Dashboard\ URL:\ ([^[:space:]]+)$ ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return 0
    fi
    if [[ "$trimmed" =~ ^dashboard_url=([^[:space:]]+)$ ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return 0
    fi
    if [[ "$trimmed" =~ ^https?://[^[:space:]]+$ ]]; then
      printf '%s' "$trimmed"
      return 0
    fi
  done <<< "$output"
  return 1
}

get_dashboard_url() {
  local extra_args=()
  local output
  while (($#)); do
    if [[ "$1" != "--no-open" ]]; then
      extra_args+=("$1")
    fi
    shift
  done
  output="$("$openclaw_bin" dashboard --no-open "${extra_args[@]}" 2>/dev/null || true)"
  extract_dashboard_url "$output" || true
}

probe_http_code() {
  local url="$1"
  if ! command -v curl >/dev/null 2>&1; then
    printf '000'
    return 0
  fi
  local code
  code="$(curl --noproxy '*' -m 4 -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
  if [[ -z "$code" ]]; then
    printf '000'
  else
    printf '%s' "$code"
  fi
}

wait_for_gateway_up() {
  local stable_hits=0
  local health_code
  for _try in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    health_code="$(probe_http_code "$HEALTH_URL")"
    if [[ "$health_code" == "200" ]]; then
      stable_hits=$((stable_hits + 1))
      if [[ "$stable_hits" -ge 2 ]]; then
        return 0
      fi
    else
      stable_hits=0
    fi
    sleep 1
  done
  return 1
}

if [[ "${1:-}" == "dashboard" ]]; then
  shift || true
  no_open=0
  for arg in "$@"; do
    if [[ "$arg" == "--no-open" ]]; then
      no_open=1
      break
    fi
  done
  url="$(get_dashboard_url "$@")"
  if [[ -z "$url" ]]; then
    url="$(resolve_control_ui_url)"
  fi
  if ! wait_for_gateway_up; then
    printf "Gateway not reachable at '%s'\n" "$DASHBOARD_URL_BASE"
    exit 1
  fi
  if [[ "$no_open" -eq 0 ]]; then
    open_windows_url "$url" || true
  fi
  printf 'dashboard_url=%s\n' "$url"
  exit 0
fi

exec powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$entry_script" "$@"
