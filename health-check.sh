#!/usr/bin/env bash
# Health and preflight checks for the KoboldCPP RunPod template.
# This file is sourceable and is also used directly by Docker HEALTHCHECK.

set -Eeuo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-/opt/koboldcpp}"
KCPP_HOME="${KCPP_HOME:-$SCRIPT_DIR}"
KCPP_BIN_DIR="${KCPP_BIN_DIR:-$KCPP_HOME/bin}"
KCPP_RELEASE_DIR="${KCPP_RELEASE_DIR:-$KCPP_HOME/releases}"
KCPP_STATUS_FILE="${KCPP_STATUS_FILE:-/logs/koboldcpp-status.json}"
HEALTH_LOG_FILE="${HEALTH_LOG_FILE:-/logs/health.log}"
HEALTH_PORT="${HEALTH_PORT:-8080}"
KCPP_PORT="${KCPP_PORT:-5001}"
KCPP_MODEL_DIR="${KCPP_MODEL_DIR:-/workspace/models}"
KCPP_MODEL="${KCPP_MODEL:-}"
KCPP_PRESET="${KCPP_PRESET:-balanced}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

source "${SCRIPT_DIR}/gpu-detect.sh"
source "${SCRIPT_DIR}/auto-patch.sh"

health_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

health_log() {
  local message="${*:-}"
  mkdir -p "$(dirname "$HEALTH_LOG_FILE")" 2>/dev/null || true
  printf '[%s] [health] %s\n' "$(health_timestamp)" "$message" | tee -a "$HEALTH_LOG_FILE"
}

health_discord_notify() {
  local title="${1:-KoboldCPP Health Alert}"
  local body="${2:-}"

  [[ -n "$DISCORD_WEBHOOK_URL" ]] || return 0

  python3 - "$DISCORD_WEBHOOK_URL" "$title" "$body" <<'PY' >/dev/null 2>&1 || true
import json
import sys
import urllib.request

webhook_url, title, body = sys.argv[1:4]
payload = {"content": f"**{title}**\n{body}"[:1900]}
req = urllib.request.Request(
    webhook_url,
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json", "User-Agent": "RunPod-KoboldCPP-Template"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=15):
    pass
PY
}

health_write_status() {
  local status="${1:-unknown}"
  local message="${2:-}"
  local backend="${3:-$(gpu_detect_backend)}"
  local binary="${4:-$(auto_patch_runtime_path "$backend")}" 
  local model="${5:-${KCPP_MODEL:-}}"

  mkdir -p "$(dirname "$KCPP_STATUS_FILE")" 2>/dev/null || true

  python3 - "$status" "$message" "$backend" "$binary" "$model" "$KCPP_PORT" "$HEALTH_PORT" <<'PY'
import json
import os
import pathlib
import sys
from datetime import datetime, timezone

status, message, backend, binary, model, kcpp_port, health_port = sys.argv[1:8]
status_file = pathlib.Path(os.environ.get("KCPP_STATUS_FILE", "/logs/koboldcpp-status.json"))
status_file.parent.mkdir(parents=True, exist_ok=True)
tmp_file = status_file.with_suffix(status_file.suffix + ".tmp")

payload = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "status": status,
    "message": message,
    "backend": backend,
    "binary": binary,
    "model": model,
    "kcpp_port": int(kcpp_port),
    "health_port": int(health_port),
    "preset": os.environ.get("KCPP_PRESET", "balanced"),
    "repair_attempts": int(os.environ.get("KCPP_REPAIR_ATTEMPTS", "0") or 0),
    "safe_mode_reason": os.environ.get("KCPP_SAFE_MODE_REASON", ""),
    "gpu_name": os.environ.get("GPU_NAME", ""),
    "mi300x": os.environ.get("GPU_IS_MI300X", "0") == "1",
}

tmp_file.write_text(json.dumps(payload, indent=2, sort_keys=True))
tmp_file.replace(status_file)
PY

  if [[ "$status" == "error" || "$status" == "safe_mode" ]]; then
    health_discord_notify "KoboldCPP ${status}" "Backend: ${backend}\nMessage: ${message}\nModel: ${model}\nBinary: ${binary}"
  fi
}

health_check_library_patterns() {
  local pattern
  for pattern in "$@"; do
    if ! ldconfig -p 2>/dev/null | grep -qi "$pattern"; then
      return 1
    fi
  done
}

health_version_at_least() {
  local current="${1:?current version required}"
  local minimum="${2:?minimum version required}"

  python3 - "$current" "$minimum" <<'PY'
import sys

def parse(value: str):
    parts = []
    for chunk in value.strip().split('.'):
        digits = ''.join(ch for ch in chunk if ch.isdigit())
        if digits:
            parts.append(int(digits))
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])

current = parse(sys.argv[1])
minimum = parse(sys.argv[2])
raise SystemExit(0 if current >= minimum else 1)
PY
}

health_check_rocm_version() {
  local version

  if ! command -v hipconfig >/dev/null 2>&1; then
    return 1
  fi

  version="$(hipconfig --version 2>/dev/null | tr -d '\r' | grep -Eo '[0-9]+(\.[0-9]+){1,2}' | head -n1 || true)"
  if [[ -z "$version" ]]; then
    return 1
  fi

  health_version_at_least "$version" "6.1.0"
}

health_check_port_open() {
  local port="${1:?port required}"
  python3 - "$port" <<'PY'
import socket
import sys
port = int(sys.argv[1])
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.settimeout(1.0)
    raise SystemExit(0 if sock.connect_ex(("127.0.0.1", port)) == 0 else 1)
PY
}

health_wait_for_port() {
  local port="${1:?port required}"
  local timeout_seconds="${2:-60}"
  local start now
  start="$(date +%s)"

  while true; do
    if health_check_port_open "$port"; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout_seconds )); then
      return 1
    fi
    sleep 1
  done
}

health_check_http_json() {
  local port="${1:?port required}"
  python3 - "$port" <<'PY'
import json
import urllib.request
import sys
port = int(sys.argv[1])
url = f"http://127.0.0.1:{port}/health"
with urllib.request.urlopen(url, timeout=5) as resp:
    payload = json.load(resp)
status = str(payload.get("status", "")).lower()
if status in {"ok", "ready", "degraded", "safe_mode", "booting", "starting"}:
    raise SystemExit(0)
raise SystemExit(1)
PY
}

health_check_backend_dependencies() {
  local backend="${1:-$(gpu_detect_backend)}"
  local lib

  case "$backend" in
    amd)
      gpu_detect_amd_ready || return 1
      if gpu_detect_is_mi300x; then
        health_log "MI300X adapter detected via rocminfo"
      else
        health_log "AMD GPU detected; MI300X signature not visible but continuing"
      fi

      if ! health_check_rocm_version; then
        health_log "ROCm version check failed; MI300X requires ROCm 6.1.0 or newer"
        return 1
      fi

      health_check_library_patterns \
        'libamdhip64' \
        'libhipblas' \
        'libhiprtc' \
        'libhsa-runtime64' \
        'librocblas'
      ;;
    nvidia)
      gpu_detect_nvidia_ready || return 1
      health_check_library_patterns 'libcuda' 'libcudart' 'libcublas'
      ;;
    cpu)
      if [[ "${ALLOW_CPU_FALLBACK:-0}" == "1" ]]; then
        health_log "CPU fallback explicitly allowed"
        return 0
      fi
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

health_check_runtime_binary() {
  local backend="${1:-$(gpu_detect_backend)}"
  local runtime
  runtime="$(auto_patch_runtime_path "$backend")"

  [[ -x "$runtime" ]] || return 1

  if [[ ! -f "$(auto_patch_metadata_path "$backend")" ]]; then
    return 1
  fi

  auto_patch_validate_runtime "$backend"
}

health_check_release_fresh() {
  local backend="${1:-$(gpu_detect_backend)}"
  auto_patch_release_is_current "$backend"
}

health_check_model_selection() {
  if [[ -n "${KCPP_MODEL:-}" && ! -f "${KCPP_MODEL}" ]]; then
    return 1
  fi

  if [[ -n "${KCPP_MODEL:-}" ]]; then
    return 0
  fi

  # When the downloader has not run yet, a missing model is acceptable during boot.
  return 0
}

health_check_full() {
  local backend="${1:-$(gpu_detect_backend)}"

  health_log "preflight starting for backend=$backend"
  health_check_backend_dependencies "$backend" || return 1
  health_check_runtime_binary "$backend" || return 1
  health_check_release_fresh "$backend" || return 1
  health_check_model_selection || return 1
  health_log "preflight completed successfully for backend=$backend"
  return 0
}

health_check_probe() {
  local port="${1:-$HEALTH_PORT}"

  if ! health_check_http_json "$port"; then
    return 1
  fi

  return 0
}

health_main() {
  local mode="${1:-full}"
  local backend
  backend="$(gpu_detect_backend)"

  health_write_status "booting" "health check starting" "$backend"

  case "$mode" in
    full|boot|preflight)
      if health_check_full "$backend"; then
        health_write_status "ready" "preflight checks passed" "$backend"
        return 0
      fi
      health_write_status "error" "preflight checks failed" "$backend"
      return 1
      ;;
    probe)
      if health_check_probe "$HEALTH_PORT"; then
        return 0
      fi
      return 1
      ;;
    backend)
      if health_check_backend_dependencies "$backend"; then
        return 0
      fi
      return 1
      ;;
    *)
      if health_check_full "$backend"; then
        health_write_status "ready" "preflight checks passed" "$backend"
        return 0
      fi
      health_write_status "error" "preflight checks failed" "$backend"
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  health_main "${1:-full}"
fi
