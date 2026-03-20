#!/usr/bin/env bash
# Auto-heal and release-update helpers for the KoboldCPP RunPod template.
# This script is safe to source from other scripts.

set -Eeuo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-/opt/koboldcpp}"
KCPP_HOME="${KCPP_HOME:-$SCRIPT_DIR}"
KCPP_BIN_DIR="${KCPP_BIN_DIR:-$KCPP_HOME/bin}"
KCPP_RELEASE_DIR="${KCPP_RELEASE_DIR:-$KCPP_HOME/releases}"
KCPP_SOURCE_DIR="${KCPP_SOURCE_DIR:-$KCPP_HOME/source}"
KCPP_ROCM_REPO="${KCPP_ROCM_REPO:-YellowRoseCx/koboldcpp-rocm}"
KCPP_CUDA_REPO="${KCPP_CUDA_REPO:-LostRuins/koboldcpp}"
KCPP_MIN_ROCM_TAG="${KCPP_MIN_ROCM_TAG:-v1.104.yr0-ROCm}"
HEALTH_LOG_FILE="${HEALTH_LOG_FILE:-/logs/health.log}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

source "${SCRIPT_DIR}/gpu-detect.sh"

auto_patch_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

auto_patch_log() {
  local message="${*:-}"
  mkdir -p "$(dirname "$HEALTH_LOG_FILE")" 2>/dev/null || true
  printf '[%s] [auto-patch] %s\n' "$(auto_patch_timestamp)" "$message" | tee -a "$HEALTH_LOG_FILE"
}

auto_patch_discord_notify() {
  local title="${1:-KoboldCPP Update}"
  local body="${2:-}"

  [[ -n "$DISCORD_WEBHOOK_URL" ]] || return 0

  python3 - "$DISCORD_WEBHOOK_URL" "$title" "$body" <<'PY' >/dev/null 2>&1 || true
import json
import sys
import urllib.request

webhook_url, title, body = sys.argv[1:4]
payload = {
    "content": f"**{title}**\n{body}"[:1900],
}
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

auto_patch_backend_repo() {
  local backend="${1:-$(gpu_detect_backend)}"
  gpu_detect_repo_for_backend "$backend"
}

auto_patch_runtime_path() {
  local backend="${1:-$(gpu_detect_backend)}"
  printf '%s/koboldcpp-%s' "$KCPP_BIN_DIR" "$backend"
}

auto_patch_payload_path() {
  local backend="${1:-$(gpu_detect_backend)}"
  printf '%s/koboldcpp-%s.payload' "$KCPP_BIN_DIR" "$backend"
}

auto_patch_mode_path() {
  local backend="${1:-$(gpu_detect_backend)}"
  printf '%s/koboldcpp-%s.mode' "$KCPP_BIN_DIR" "$backend"
}

auto_patch_metadata_path() {
  local backend="${1:-$(gpu_detect_backend)}"
  printf '%s/%s.json' "$KCPP_RELEASE_DIR" "$backend"
}

auto_patch_local_metadata_path() {
  auto_patch_metadata_path "$1"
}

auto_patch_resolve_release_metadata() {
  local backend="${1:-$(gpu_detect_backend)}"
  local repo
  repo="$(auto_patch_backend_repo "$backend")"

  python3 - "$repo" "$backend" "$KCPP_MIN_ROCM_TAG" <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

repo, backend, min_tag = sys.argv[1:4]
api_url = f"https://api.github.com/repos/{repo}/releases/latest"
headers = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "RunPod-KoboldCPP-Template",
}
if os.environ.get("GITHUB_TOKEN"):
    headers["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"
elif os.environ.get("HF_TOKEN"):
    headers["Authorization"] = f"Bearer {os.environ['HF_TOKEN']}"

req = urllib.request.Request(api_url, headers=headers)
try:
    with urllib.request.urlopen(req, timeout=60) as resp:
        release = json.load(resp)
except Exception as exc:
    raise SystemExit(f"failed to query GitHub release metadata for {repo}: {exc}")

assets = release.get("assets", []) or []

def version_tuple(tag: str):
    import re
    m = re.search(r"v?(\d+)\.(\d+)(?:\.yr(\d+))?", tag or "", re.IGNORECASE)
    if m:
        return tuple(int(x or 0) for x in m.groups())
    m = re.search(r"(\d+)(?:\.(\d+))?(?:\.(\d+))?", tag or "")
    if not m:
        return ()
    parts = [int(x) for x in m.groups(default="0")]
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])

if backend == "amd" and min_tag:
    latest_version = version_tuple(release.get("tag_name", ""))
    minimum_version = version_tuple(min_tag)
    if not latest_version or not minimum_version or latest_version < minimum_version:
        raise SystemExit(f"latest ROCm release {release.get('tag_name', '')!r} is older than required minimum {min_tag!r}")

# Prefer Linux x86_64 assets; avoid checksums and signatures.
def score(asset):
    name = (asset.get("name") or "").lower()
    url = (asset.get("browser_download_url") or "").lower()
    s = 0
    if "checksum" in name or "sha" in name or "sig" in name or name.endswith(".asc"):
        s -= 1000
    if backend == "amd":
        if "rocm" in name or "hip" in name:
            s += 120
        if "linux" in name:
            s += 40
        if "x86_64" in name or "amd64" in name:
            s += 40
        if name.endswith(".py"):
            s += 10
        if name.endswith((".zip", ".tar.gz", ".tgz", ".tar.xz", ".tar")):
            s += 5
    elif backend == "nvidia":
        if "cuda" in name:
            s += 120
        if "linux" in name:
            s += 40
        if "x86_64" in name or "amd64" in name:
            s += 40
        if name.endswith(".py"):
            s += 10
        if name.endswith((".zip", ".tar.gz", ".tgz", ".tar.xz", ".tar")):
            s += 5
    else:
        if "linux" in name:
            s += 20
    if "koboldcpp" in name:
        s += 15
    if "release" in url:
        s += 1
    return s

assets = sorted(assets, key=score, reverse=True)
if not assets:
    raise SystemExit(f"no release assets found for {repo}")

asset = assets[0]
out = {
    "backend": backend,
    "repo": repo,
    "tag": release.get("tag_name", ""),
    "name": release.get("name", ""),
    "published_at": release.get("published_at", ""),
    "html_url": release.get("html_url", ""),
    "asset_name": asset.get("name", ""),
    "asset_url": asset.get("browser_download_url", ""),
    "asset_size": asset.get("size", 0),
    "asset_digest": asset.get("digest", ""),
    "prerelease": bool(release.get("prerelease", False)),
}
print(json.dumps(out, indent=2, sort_keys=True))
PY
}

auto_patch_write_metadata() {
  local backend="${1:-$(gpu_detect_backend)}"
  local meta_file="${2:-}"
  local out_file
  out_file="$(auto_patch_local_metadata_path "$backend")"
  mkdir -p "$(dirname "$out_file")" "$KCPP_BIN_DIR" "$KCPP_RELEASE_DIR"
  cp -f "$meta_file" "$out_file"
}

auto_patch_install_from_metadata() {
  local backend="${1:-$(gpu_detect_backend)}"
  local meta_file="${2:?metadata json file required}"
  local out_file
  out_file="$(auto_patch_local_metadata_path "$backend")"
  mkdir -p "$KCPP_BIN_DIR" "$KCPP_RELEASE_DIR"

  python3 - "$backend" "$meta_file" "$KCPP_BIN_DIR" "$out_file" <<'PY'
import hashlib
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from datetime import datetime, timezone

backend, meta_path, bin_dir, out_meta_path = sys.argv[1:5]
meta = json.loads(pathlib.Path(meta_path).read_text())
asset_url = meta["asset_url"]
asset_name = meta["asset_name"]
repo = meta["repo"]
tag = meta["tag"]

bin_dir = pathlib.Path(bin_dir)
bin_dir.mkdir(parents=True, exist_ok=True)
out_meta_path = pathlib.Path(out_meta_path)

payload_path = bin_dir / f"koboldcpp-{backend}.payload"
mode_path = bin_dir / f"koboldcpp-{backend}.mode"
wrapper_path = bin_dir / f"koboldcpp-{backend}"

tmp_dl = pathlib.Path(tempfile.mkstemp(prefix="kcpp-asset-", suffix=pathlib.Path(asset_name).suffix or ".bin")[1])
try:
    req = urllib.request.Request(asset_url, headers={"User-Agent": "RunPod-KoboldCPP-Template"})
    with urllib.request.urlopen(req, timeout=600) as resp, tmp_dl.open("wb") as fh:
        shutil.copyfileobj(resp, fh)

    def looks_like_archive(path: pathlib.Path) -> bool:
        head = path.read_bytes()[:8]
        return head.startswith(b"PK\x03\x04") or head.startswith(b"\x1f\x8b") or head.startswith(b"BZh") or head.startswith(b"\xfd7zXZ")

    def extract_best_archive_member(archive_path: pathlib.Path) -> pathlib.Path:
        candidates = []
        if zipfile.is_zipfile(archive_path):
            with zipfile.ZipFile(archive_path) as zf:
                infos = [i for i in zf.infolist() if not i.is_dir()]
                def rank(name: str) -> tuple[int, int, str]:
                    lower = name.lower()
                    score = 0
                    if "koboldcpp" in lower:
                        score += 100
                    if lower.endswith(".py"):
                        score += 50
                    if lower.endswith((".sh", ".bin", ".exe")):
                        score += 10
                    return (-score, len(lower), lower)
                infos.sort(key=lambda i: rank(i.filename))
                best = infos[0]
                target = payload_path
                with zf.open(best) as src, target.open("wb") as dst:
                    shutil.copyfileobj(src, dst)
                return target
        if tarfile.is_tarfile(archive_path):
            with tarfile.open(archive_path) as tf:
                members = [m for m in tf.getmembers() if m.isfile()]
                def rank(member):
                    lower = member.name.lower()
                    score = 0
                    if "koboldcpp" in lower:
                        score += 100
                    if lower.endswith(".py"):
                        score += 50
                    if lower.endswith((".sh", ".bin")):
                        score += 10
                    return (-score, len(lower), lower)
                members.sort(key=rank)
                best = members[0]
                with tf.extractfile(best) as src, payload_path.open("wb") as dst:
                    shutil.copyfileobj(src, dst)
                return payload_path
        return archive_path

    source_path = tmp_dl
    if looks_like_archive(tmp_dl):
        source_path = extract_best_archive_member(tmp_dl)
    else:
        shutil.copy2(tmp_dl, payload_path)
        source_path = payload_path

    if source_path != payload_path:
        shutil.copy2(source_path, payload_path)

    first_bytes = payload_path.read_bytes()[:256]
    is_python = payload_path.suffix == ".py" or first_bytes.lstrip().startswith(b"#!") and b"python" in first_bytes.lower()
    mode = "python" if is_python else "exec"

    payload_path.chmod(payload_path.stat().st_mode | stat.S_IEXEC)
    wrapper_contents = f'''#!/usr/bin/env bash
set -Eeuo pipefail
payload="{payload_path}"
mode_file="{mode_path}"
mode="$(cat "$mode_file" 2>/dev/null || printf 'exec')"
case "$mode" in
  python)
    exec python3 "$payload" "$@"
    ;;
  exec|*)
    exec "$payload" "$@"
    ;;
esac
'''
    wrapper_path.write_text(wrapper_contents)
    wrapper_path.chmod(0o755)
    mode_path.write_text(mode)

    sha256 = hashlib.sha256(payload_path.read_bytes()).hexdigest()
    local_meta = dict(meta)
    local_meta.update({
        "downloaded_at": datetime.now(timezone.utc).isoformat(),
        "payload_path": str(payload_path),
        "wrapper_path": str(wrapper_path),
        "mode": mode,
        "sha256": sha256,
    })
    out_meta_path.write_text(json.dumps(local_meta, indent=2, sort_keys=True))
finally:
    try:
        tmp_dl.unlink(missing_ok=True)
    except Exception:
        pass
PY
}

auto_patch_validate_runtime() {
  local backend="${1:-$(gpu_detect_backend)}"
  local runtime
  runtime="$(auto_patch_runtime_path "$backend")"

  if [[ ! -x "$runtime" ]]; then
    return 1
  fi

  timeout 30s "$runtime" --help >/dev/null 2>&1 || timeout 30s "$runtime" -h >/dev/null 2>&1
}

auto_patch_source_repair() {
  local backend="${1:-$(gpu_detect_backend)}"
  if [[ ! -d "$KCPP_SOURCE_DIR/.git" ]]; then
    return 1
  fi

  auto_patch_log "source checkout detected at $KCPP_SOURCE_DIR; pulling latest patch layer"
  git -C "$KCPP_SOURCE_DIR" pull --ff-only

  if [[ -n "${KCPP_SOURCE_BUILD_CMD:-}" ]]; then
    auto_patch_log "running custom source build command: $KCPP_SOURCE_BUILD_CMD"
    (cd "$KCPP_SOURCE_DIR" && bash -lc "$KCPP_SOURCE_BUILD_CMD")
  fi

  return 0
}

auto_patch_repair_runtime() {
  local backend="${1:-$(gpu_detect_backend)}"
  local meta_file
  meta_file="$(mktemp)"

  auto_patch_log "repair requested for backend=$backend"

  if [[ "${KCPP_ENABLE_SOURCE_REPAIR:-0}" == "1" ]]; then
    if auto_patch_source_repair "$backend"; then
      auto_patch_log "source repair step completed"
    else
      auto_patch_log "source repair unavailable or failed; falling back to release binary refresh"
    fi
  fi

  if ! auto_patch_resolve_release_metadata "$backend" >"$meta_file"; then
    auto_patch_log "failed to resolve latest release metadata for backend=$backend"
    rm -f "$meta_file"
    return 1
  fi

  auto_patch_log "installing latest release for backend=$backend"
  if ! auto_patch_install_from_metadata "$backend" "$meta_file"; then
    auto_patch_log "installation failed for backend=$backend"
    rm -f "$meta_file"
    return 1
  fi

  if ! auto_patch_validate_runtime "$backend"; then
    auto_patch_log "runtime validation failed for backend=$backend"
    rm -f "$meta_file"
    return 1
  fi

  auto_patch_log "backend=$backend repair completed successfully"
  rm -f "$meta_file"
  return 0
}

auto_patch_release_is_current() {
  local backend="${1:-$(gpu_detect_backend)}"
  local local_meta latest_meta
  local_meta="$(auto_patch_local_metadata_path "$backend")"
  latest_meta="$(mktemp)"

  if [[ ! -f "$local_meta" ]]; then
    rm -f "$latest_meta"
    return 1
  fi

  if ! auto_patch_resolve_release_metadata "$backend" >"$latest_meta"; then
    rm -f "$latest_meta"
    return 1
  fi

  python3 - "$local_meta" "$latest_meta" <<'PY'
import json
import sys
from pathlib import Path

local_meta = json.loads(Path(sys.argv[1]).read_text())
latest_meta = json.loads(Path(sys.argv[2]).read_text())

same = (
    local_meta.get("tag") == latest_meta.get("tag")
    and local_meta.get("asset_name") == latest_meta.get("asset_name")
    and local_meta.get("asset_digest", "") == latest_meta.get("asset_digest", "")
)
raise SystemExit(0 if same else 1)
PY
  local rc=$?
  rm -f "$latest_meta"
  return "$rc"
}

auto_patch_check_for_updates() {
  local backend="${1:-$(gpu_detect_backend)}"
  local latest_meta local_meta current_tag='' latest_tag='' current_repo='' latest_repo='' current_asset='' latest_asset='' current_url='' latest_url=''
  latest_meta="$(mktemp)"
  local_meta="$(auto_patch_local_metadata_path "$backend" 2>/dev/null || true)"

  if ! auto_patch_resolve_release_metadata "$backend" >"$latest_meta"; then
    auto_patch_log "update notifier unavailable for backend=$backend"
    rm -f "$latest_meta"
    return 0
  fi

  latest_tag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("tag", ""))' "$latest_meta")"
  latest_repo="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("repo", ""))' "$latest_meta")"
  latest_asset="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("asset_name", ""))' "$latest_meta")"
  latest_url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("html_url", ""))' "$latest_meta")"

  if [[ -f "$local_meta" ]]; then
    current_tag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("tag", ""))' "$local_meta")"
    current_repo="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("repo", ""))' "$local_meta")"
    current_asset="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("asset_name", ""))' "$local_meta")"
    current_url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("html_url", ""))' "$local_meta")"
  fi

  if [[ -z "$current_tag" ]]; then
    auto_patch_log "latest $backend release detected: $latest_repo $latest_tag ($latest_asset)"
    auto_patch_discord_notify "KoboldCPP release detected" "Backend: ${backend}\nLatest: ${latest_tag}\nAsset: ${latest_asset}\nURL: ${latest_url}"
    rm -f "$latest_meta"
    return 0
  fi

  if [[ "$current_tag" != "$latest_tag" || "$current_asset" != "$latest_asset" ]]; then
    auto_patch_log "update available for $backend: $current_tag -> $latest_tag ($latest_asset)"
    auto_patch_discord_notify "KoboldCPP update available" "Backend: ${backend}\nCurrent: ${current_tag}\nLatest: ${latest_tag}\nAsset: ${latest_asset}\nURL: ${latest_url}"
  else
    auto_patch_log "release already current for $backend: $current_tag ($current_asset)"
  fi

  rm -f "$latest_meta"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  backend="${1:-$(gpu_detect_backend)}"
  if auto_patch_repair_runtime "$backend"; then
    exit 0
  fi
  exit 1
fi
