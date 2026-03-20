#!/usr/bin/env bash
# GPU detection helpers for the KoboldCPP RunPod template.
# This file is intentionally sourceable from other scripts.

gpu_detect_has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

gpu_detect_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

gpu_detect_log() {
  local message="${*:-}"
  local log_file="${HEALTH_LOG_FILE:-/logs/health.log}"
  mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
  printf '[%s] [gpu-detect] %s\n' "$(gpu_detect_timestamp)" "$message" | tee -a "$log_file"
}

gpu_detect_nvidia_ready() {
  if gpu_detect_has_cmd nvidia-smi && [[ -e /dev/nvidia0 || -n "${CUDA_VISIBLE_DEVICES:-}" ]]; then
    return 0
  fi
  return 1
}

gpu_detect_amd_ready() {
  if [[ ! -e /dev/kfd && ! -d /sys/class/kfd ]]; then
    return 1
  fi

  if ! gpu_detect_has_cmd rocminfo; then
    return 1
  fi

  if ! rocminfo >/dev/null 2>&1; then
    return 1
  fi

  return 0
}

gpu_detect_backend() {
  local override="${KCPP_BACKEND:-auto}"

  case "$override" in
    amd|nvidia|cpu)
      printf '%s\n' "$override"
      return 0
      ;;
  esac

  if gpu_detect_nvidia_ready; then
    printf 'nvidia\n'
    return 0
  fi

  if gpu_detect_amd_ready; then
    printf 'amd\n'
    return 0
  fi

  printf 'cpu\n'
}

gpu_detect_gpu_name() {
  if gpu_detect_nvidia_ready && gpu_detect_has_cmd nvidia-smi; then
    nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1
    return 0
  fi

  if gpu_detect_amd_ready && gpu_detect_has_cmd rocminfo; then
    local name
    name="$(rocminfo 2>/dev/null | awk -F': ' '/Marketing Name/ {print $2; exit} /Name: gfx/ {print $2; exit}')"
    if [[ -n "$name" ]]; then
      printf '%s\n' "$name"
      return 0
    fi
  fi

  printf 'CPU fallback\n'
}

gpu_detect_is_mi300x() {
  if ! gpu_detect_has_cmd rocminfo; then
    return 1
  fi

  if rocminfo 2>/dev/null | grep -qiE 'gfx942|MI300X'; then
    return 0
  fi

  return 1
}

gpu_detect_required_libraries() {
  local backend="${1:-$(gpu_detect_backend)}"

  case "$backend" in
    amd)
      printf '%s\n' \
        'libamdhip64' \
        'libhipblas' \
        'libhiprtc' \
        'libhsa-runtime64' \
        'librocblas'
      ;;
    nvidia)
      printf '%s\n' \
        'libcuda' \
        'libcudart' \
        'libcublas'
      ;;
    *)
      :
      ;;
  esac
}

gpu_detect_repo_for_backend() {
  local backend="${1:-$(gpu_detect_backend)}"

  case "$backend" in
    amd)
      printf '%s\n' "${KCPP_ROCM_REPO:-YellowRoseCx/koboldcpp-rocm}"
      ;;
    nvidia|cpu)
      printf '%s\n' "${KCPP_CUDA_REPO:-LostRuins/koboldcpp}"
      ;;
    *)
      printf '%s\n' "${KCPP_CUDA_REPO:-LostRuins/koboldcpp}"
      ;;
  esac
}

gpu_detect_summary() {
  local backend name mi300x amd_ready nvidia_ready

  backend="$(gpu_detect_backend)"
  name="$(gpu_detect_gpu_name)"

  amd_ready=0
  nvidia_ready=0
  mi300x=0

  gpu_detect_amd_ready && amd_ready=1 || true
  gpu_detect_nvidia_ready && nvidia_ready=1 || true
  gpu_detect_is_mi300x && mi300x=1 || true

  cat <<EOF
backend=$backend
name=$name
amd_ready=$amd_ready
nvidia_ready=$nvidia_ready
mi300x=$mi300x
EOF
}

gpu_detect_main() {
  local mode="${1:-shell}"
  local backend name amd_ready nvidia_ready mi300x

  backend="$(gpu_detect_backend)"
  name="$(gpu_detect_gpu_name)"

  amd_ready=0
  nvidia_ready=0
  mi300x=0

  gpu_detect_amd_ready && amd_ready=1 || true
  gpu_detect_nvidia_ready && nvidia_ready=1 || true
  gpu_detect_is_mi300x && mi300x=1 || true

  case "$mode" in
    json)
      python3 - "$backend" "$name" "$amd_ready" "$nvidia_ready" "$mi300x" <<'PY'
import json, sys
payload = {
    "backend": sys.argv[1],
    "name": sys.argv[2],
    "amd_ready": sys.argv[3] == "1",
    "nvidia_ready": sys.argv[4] == "1",
    "mi300x": sys.argv[5] == "1",
}
print(json.dumps(payload, indent=2, sort_keys=True))
PY
      ;;
    shell|export|*)
      printf 'GPU_BACKEND=%q\n' "$backend"
      printf 'GPU_NAME=%q\n' "$name"
      printf 'GPU_AMD_READY=%q\n' "$amd_ready"
      printf 'GPU_NVIDIA_READY=%q\n' "$nvidia_ready"
      printf 'GPU_IS_MI300X=%q\n' "$mi300x"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  gpu_detect_main "${1:-shell}"
fi
