#!/usr/bin/env bash
# Main container entrypoint for the KoboldCPP RunPod template.
#
# Responsibilities:
#   1) Bootstrap logs and status files.
#   2) Detect the active GPU backend.
#   3) Heal or refresh the correct KoboldCPP runtime.
#   4) Optionally pre-download community models from Hugging Face.
#   5) Launch a lightweight /health server and then KoboldCPP itself.

set -Eeuo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-/opt/koboldcpp}"
KCPP_HOME="${KCPP_HOME:-$SCRIPT_DIR}"
KCPP_BIN_DIR="${KCPP_BIN_DIR:-$KCPP_HOME/bin}"
KCPP_RELEASE_DIR="${KCPP_RELEASE_DIR:-$KCPP_HOME/releases}"
KCPP_MODEL_DIR="${KCPP_MODEL_DIR:-/workspace/models}"
KCPP_CACHE_DIR="${KCPP_CACHE_DIR:-/workspace/cache}"
KCPP_LOG_DIR="${KCPP_LOG_DIR:-/logs}"
KCPP_STATUS_FILE="${KCPP_STATUS_FILE:-${KCPP_LOG_DIR}/koboldcpp-status.json}"
HEALTH_LOG_FILE="${HEALTH_LOG_FILE:-${KCPP_LOG_DIR}/health.log}"
HEALTH_PORT="${HEALTH_PORT:-8080}"
KCPP_PORT="${KCPP_PORT:-5001}"
KCPP_HOST="${KCPP_HOST:-0.0.0.0}"
KCPP_BACKEND="${KCPP_BACKEND:-auto}"
KCPP_RUNTIME_MODE="${KCPP_RUNTIME_MODE:-auto}"
KCPP_PRESET="${KCPP_PRESET:-balanced}"
AUTO_HEAL="${AUTO_HEAL:-1}"
SAFE_MODE="${SAFE_MODE:-0}"
ALLOW_CPU_FALLBACK="${ALLOW_CPU_FALLBACK:-0}"
AUTO_DOWNLOAD_MODELS="${AUTO_DOWNLOAD_MODELS:-1}"
KCPP_THREADS="${KCPP_THREADS:-0}"
KCPP_BLAS_THREADS="${KCPP_BLAS_THREADS:-0}"
KCPP_CONTEXT_SIZE="${KCPP_CONTEXT_SIZE:-8192}"
KCPP_GPU_LAYERS="${KCPP_GPU_LAYERS:-999}"
KCPP_EXTRA_ARGS="${KCPP_EXTRA_ARGS:-}"
KCPP_MODEL="${KCPP_MODEL:-}"
KCPP_ENABLE_SOURCE_REPAIR="${KCPP_ENABLE_SOURCE_REPAIR:-0}"
KCPP_REPAIR_ATTEMPTS=0

mkdir -p "$KCPP_BIN_DIR" "$KCPP_RELEASE_DIR" "$KCPP_MODEL_DIR" "$KCPP_CACHE_DIR" "$KCPP_LOG_DIR"
touch "$HEALTH_LOG_FILE"
exec > >(tee -a "$HEALTH_LOG_FILE") 2>&1

source "${SCRIPT_DIR}/gpu-detect.sh"
source "${SCRIPT_DIR}/auto-patch.sh"
source "${SCRIPT_DIR}/health-check.sh"

log() {
  printf '[%s] [entrypoint] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

health_server_pid=""
koboldcpp_pid=""
cleanup() {
  local rc=$?
  log "shutdown requested (exit=${rc})"
  if [[ -n "${koboldcpp_pid:-}" ]] && kill -0 "$koboldcpp_pid" >/dev/null 2>&1; then
    kill "$koboldcpp_pid" >/dev/null 2>&1 || true
    wait "$koboldcpp_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "${health_server_pid:-}" ]] && kill -0 "$health_server_pid" >/dev/null 2>&1; then
    kill "$health_server_pid" >/dev/null 2>&1 || true
    wait "$health_server_pid" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

detect_runtime_mode() {
  local mode
  mode="$(printf '%s' "${KCPP_RUNTIME_MODE:-auto}" | tr '[:upper:]' '[:lower:]')"

  case "$mode" in
    pod|serverless)
      printf '%s\n' "$mode"
      return 0
      ;;
    auto|"")
      if [[ -n "${RUNPOD_ENDPOINT_ID:-}" || -n "${RUNPOD_SERVERLESS_URL:-}" || -n "${RUNPOD_WEBHOOK_GET_JOB:-}" ]]; then
        printf 'serverless\n'
      else
        printf 'pod\n'
      fi
      return 0
      ;;
    *)
      printf 'pod\n'
      return 0
      ;;
  esac
}

run_serverless_worker() {
  local backend
  backend="$(backend_from_env_or_gpu)"
  export GPU_NAME="$(gpu_detect_gpu_name)"
  export GPU_IS_MI300X="0"
  gpu_detect_is_mi300x && export GPU_IS_MI300X="1" || true
  export GPU_BACKEND="$backend"

  health_write_status "starting" "launching RunPod serverless handler" "$backend" "python3 ${SCRIPT_DIR}/handler.py" "${KCPP_MODEL:-}"
  log "runtime mode=serverless; launching RunPod handler"
  exec python3 "${SCRIPT_DIR}/handler.py"
}

start_health_server() {
  python3 - "$HEALTH_PORT" "$KCPP_STATUS_FILE" <<'PY' &
import json
import pathlib
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port = int(sys.argv[1])
status_file = pathlib.Path(sys.argv[2])

class Handler(BaseHTTPRequestHandler):
    def _payload(self):
        try:
            data = json.loads(status_file.read_text())
        except Exception as exc:
            data = {
                "status": "booting",
                "message": f"status file unavailable: {exc}",
                "backend": "unknown",
                "binary": "",
                "model": "",
            }
        return json.dumps(data, indent=2, sort_keys=True).encode()

    def do_GET(self):
        if self.path not in ("/", "/health", "/ready"):
            self.send_response(404)
            self.end_headers()
            return

        body = self._payload()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return

ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
PY
  health_server_pid=$!
  log "health endpoint listening on 0.0.0.0:${HEALTH_PORT} (pid=${health_server_pid})"
}

ensure_default_permissions() {
  mkdir -p "$KCPP_BIN_DIR" "$KCPP_RELEASE_DIR" "$KCPP_MODEL_DIR" "$KCPP_CACHE_DIR" "$KCPP_LOG_DIR"
  chmod -R u+rwX "$KCPP_HOME" "$KCPP_MODEL_DIR" "$KCPP_CACHE_DIR" "$KCPP_LOG_DIR" 2>/dev/null || true
}

backend_from_env_or_gpu() {
  local selected="${KCPP_BACKEND:-auto}"
  if [[ "$selected" == "auto" || -z "$selected" ]]; then
    selected="$(gpu_detect_backend)"
  fi
  case "$selected" in
    amd|nvidia|cpu)
      printf '%s\n' "$selected"
      ;;
    *)
      printf '%s\n' "$(gpu_detect_backend)"
      ;;
  esac
}

choose_model_from_downloads() {
  local preset="${KCPP_PRESET:-balanced}"
  local candidate=""
  local preset_file="${KCPP_MODEL_DIR}/.selected/${preset}.gguf"
  local default_file="${KCPP_MODEL_DIR}/.selected/default.gguf"

  if [[ -n "${KCPP_MODEL:-}" ]]; then
    printf '%s\n' "$KCPP_MODEL"
    return 0
  fi

  if [[ -L "$preset_file" || -f "$preset_file" ]]; then
    candidate="$(readlink -f "$preset_file" 2>/dev/null || printf '%s' "$preset_file")"
    printf '%s\n' "$candidate"
    return 0
  fi

  if [[ -L "$default_file" || -f "$default_file" ]]; then
    candidate="$(readlink -f "$default_file" 2>/dev/null || printf '%s' "$default_file")"
    printf '%s\n' "$candidate"
    return 0
  fi

  find "$KCPP_MODEL_DIR" -type f -name '*.gguf' 2>/dev/null | sort | head -n1
}

resolve_launch_flags() {
  local -a flags=()
  local threads blas_threads

  threads="${KCPP_THREADS:-0}"
  blas_threads="${KCPP_BLAS_THREADS:-0}"

  if [[ "$threads" == "0" || -z "$threads" ]]; then
    threads="$(nproc)"
  fi
  if [[ "$blas_threads" == "0" || -z "$blas_threads" ]]; then
    blas_threads="$threads"
  fi

  flags+=(--host "$KCPP_HOST" --port "$KCPP_PORT")
  flags+=(--threads "$threads" --blasthreads "$blas_threads")
  flags+=(--contextsize "$KCPP_CONTEXT_SIZE")
  flags+=(--gpulayers "$KCPP_GPU_LAYERS")

  if [[ -n "$KCPP_MODEL" ]]; then
    flags+=(--model "$KCPP_MODEL")
  fi

  if [[ -n "$KCPP_EXTRA_ARGS" ]]; then
    # The env var is intentionally whitespace-split so community users can paste
    # normal CLI fragments into RunPod's template UI.
    read -r -a extra <<< "$KCPP_EXTRA_ARGS"
    flags+=("${extra[@]}")
  fi

  printf '%s\0' "${flags[@]}"
}

wait_for_runtime_readiness() {
  local timeout_seconds="${1:-120}"
  health_wait_for_port "$KCPP_PORT" "$timeout_seconds"
}

select_runtime_wrapper() {
  local backend="${1:-$(gpu_detect_backend)}"
  auto_patch_runtime_path "$backend"
}

bootstrap_models_if_requested() {
  if [[ "$AUTO_DOWNLOAD_MODELS" != "1" ]]; then
    log "AUTO_DOWNLOAD_MODELS disabled; skipping community model bootstrap"
    return 0
  fi

  log "bootstrapping community models for preset=$KCPP_PRESET"
  if ! "$SCRIPT_DIR/models-download.sh"; then
    log "model bootstrap returned non-zero; continuing because runtime can still start without a local model"
  fi

  if [[ -z "${KCPP_MODEL:-}" ]]; then
    KCPP_MODEL="$(choose_model_from_downloads || true)"
    if [[ -n "$KCPP_MODEL" ]]; then
      export KCPP_MODEL
      log "selected default model: $KCPP_MODEL"
    fi
  fi
}

run_safe_mode() {
  local reason="${1:-Unknown repair failure}"
  export SAFE_MODE=1
  export KCPP_SAFE_MODE_REASON="$reason"
  health_write_status "safe_mode" "$reason" "$(gpu_detect_backend)" "" "${KCPP_MODEL:-}"

  log "SAFE MODE ENABLED"
  log "reason: $reason"
  log "what to do next:"
  log "  1) Open /logs/health.log and review the repair failure details."
  log "  2) If you are on an AMD pod, keep KCPP_BACKEND=auto or set KCPP_BACKEND=amd explicitly."
  log "  3) If the GPU is unavailable, set ALLOW_CPU_FALLBACK=1 to run in CPU mode."
  log "  4) Verify your network volume is mounted at /workspace and contains the model files."
  log "  5) Reboot the pod after correcting the runtime mismatch."

  # Keep the container alive so the operator can inspect logs and the /health
  # endpoint still returns a useful diagnostic payload.
  while true; do
    sleep 3600
  done
}

main() {
  local backend runtime_wrapper runtime_backend runtime_mode
  local -a launch_flags=()

  ensure_default_permissions
  runtime_mode="$(detect_runtime_mode)"
  log "runtime mode resolved to ${runtime_mode}"

  if [[ "$runtime_mode" == "serverless" ]]; then
    run_serverless_worker
  fi

  start_health_server
  backend="$(backend_from_env_or_gpu)"
  export GPU_NAME="$(gpu_detect_gpu_name)"
  export GPU_IS_MI300X="0"
  gpu_detect_is_mi300x && export GPU_IS_MI300X="1" || true
  export GPU_BACKEND="$backend"

  log "detected backend=$backend gpu_name=${GPU_NAME:-unknown} mi300x=${GPU_IS_MI300X:-0}"
  health_write_status "booting" "container boot sequence started" "$backend" "" "${KCPP_MODEL:-}"

  auto_patch_check_for_updates "$backend"

  bootstrap_models_if_requested

  if [[ "$AUTO_HEAL" == "1" ]]; then
    while (( KCPP_REPAIR_ATTEMPTS < 3 )); do
      KCPP_REPAIR_ATTEMPTS=$((KCPP_REPAIR_ATTEMPTS + 1))
      export KCPP_REPAIR_ATTEMPTS
      health_write_status "booting" "preflight attempt ${KCPP_REPAIR_ATTEMPTS}/3" "$backend" "" "${KCPP_MODEL:-}"

      if health_check_full "$backend"; then
        log "preflight passed on attempt ${KCPP_REPAIR_ATTEMPTS}"
        break
      fi

      log "preflight failed on attempt ${KCPP_REPAIR_ATTEMPTS}; initiating repair"
      if ! auto_patch_repair_runtime "$backend"; then
        log "repair attempt ${KCPP_REPAIR_ATTEMPTS} failed"
      fi
    done
  fi

  if ! health_check_full "$backend"; then
    run_safe_mode "Automatic repair failed after 3 attempts"
  fi

  runtime_wrapper="$(select_runtime_wrapper "$backend")"
  if [[ ! -x "$runtime_wrapper" ]]; then
    if [[ "$ALLOW_CPU_FALLBACK" == "1" ]]; then
      backend="cpu"
      runtime_wrapper="$(select_runtime_wrapper "$backend")"
    fi
  fi

  if [[ ! -x "$runtime_wrapper" ]]; then
    run_safe_mode "No runnable KoboldCPP binary was found for backend=$backend"
  fi

  if [[ -z "${KCPP_MODEL:-}" ]]; then
    KCPP_MODEL="$(choose_model_from_downloads || true)"
    [[ -n "$KCPP_MODEL" ]] && export KCPP_MODEL
  fi

  mapfile -d '' -t launch_flags < <(resolve_launch_flags)
  log "launching runtime wrapper=$runtime_wrapper"
  log "launch flags: ${launch_flags[*]}"
  health_write_status "starting" "launching KoboldCPP" "$backend" "$runtime_wrapper" "${KCPP_MODEL:-}"

  "$runtime_wrapper" "${launch_flags[@]}" &
  koboldcpp_pid=$!
  log "KoboldCPP process started pid=$koboldcpp_pid"

  if ! wait_for_runtime_readiness 180; then
    log "runtime did not open port ${KCPP_PORT} within the readiness window"
    kill "$koboldcpp_pid" >/dev/null 2>&1 || true
    wait "$koboldcpp_pid" >/dev/null 2>&1 || true
    run_safe_mode "KoboldCPP failed to become ready on port ${KCPP_PORT}"
  fi

  health_write_status "ready" "KoboldCPP is ready" "$backend" "$runtime_wrapper" "${KCPP_MODEL:-}"
  log "KoboldCPP is ready on http://${KCPP_HOST}:${KCPP_PORT}"
  log "health endpoint available at http://127.0.0.1:${HEALTH_PORT}/health"

  wait "$koboldcpp_pid"
}

main "$@"
