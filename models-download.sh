#!/usr/bin/env bash
# First-run Hugging Face model downloader for the KoboldCPP RunPod template.
#
# Supported configuration:
#   HF_MODEL_LIST      - semicolon-separated custom entries: repo_id|filename|alias
#   HF_MODEL_PRESETS   - comma-separated preset names (default derived from KCPP_PRESET)
#   HF_MODEL_QUANTIZATION - preferred quantization token, e.g. Q4_K_M
#   HF_TOKEN           - optional Hugging Face token for private repos
#   FORCE_MODEL_DOWNLOAD=1 - ignore the completion marker and run again

set -Eeuo pipefail

MODELS_DIR="${KCPP_MODEL_DIR:-/workspace/models}"
PRESETS_DIR="${MODELS_DIR}/.selected"
MARKER_FILE="${MODELS_DIR}/.koboldcpp-model-download-complete"
MANIFEST_FILE="${MODELS_DIR}/.koboldcpp-model-manifest.json"
HF_MODEL_QUANTIZATION="${HF_MODEL_QUANTIZATION:-Q4_K_M}"
HF_MODEL_LIST="${HF_MODEL_LIST:-}"
HF_MODEL_PRESETS="${HF_MODEL_PRESETS:-}"
KCPP_PRESET="${KCPP_PRESET:-balanced}"
AUTO_DOWNLOAD_MODELS="${AUTO_DOWNLOAD_MODELS:-1}"
HEALTH_LOG_FILE="${HEALTH_LOG_FILE:-/logs/health.log}"

mkdir -p "$MODELS_DIR" "$PRESETS_DIR" "$(dirname "$HEALTH_LOG_FILE")"

log() {
  printf '[%s] [models] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" | tee -a "$HEALTH_LOG_FILE"
}

if [[ "$AUTO_DOWNLOAD_MODELS" != "1" ]]; then
  log "AUTO_DOWNLOAD_MODELS is disabled; skipping model bootstrap"
  exit 0
fi

if [[ -f "$MARKER_FILE" && "${FORCE_MODEL_DOWNLOAD:-0}" != "1" ]]; then
  log "model bootstrap already completed; skipping"
  exit 0
fi

python3 - "$MODELS_DIR" "$PRESETS_DIR" "$MARKER_FILE" "$MANIFEST_FILE" "$HF_MODEL_QUANTIZATION" "$HF_MODEL_LIST" "$HF_MODEL_PRESETS" "$KCPP_PRESET" <<'PY'
import hashlib
import json
import os
import pathlib
import shutil
import sys
import tempfile
import urllib.request
from datetime import datetime, timezone

MODELS_DIR = pathlib.Path(sys.argv[1])
PRESETS_DIR = pathlib.Path(sys.argv[2])
MARKER_FILE = pathlib.Path(sys.argv[3])
MANIFEST_FILE = pathlib.Path(sys.argv[4])
PREFERRED_QUANT = sys.argv[5].strip()
HF_MODEL_LIST = sys.argv[6].strip()
HF_MODEL_PRESETS = sys.argv[7].strip()
KCPP_PRESET = sys.argv[8].strip() or "balanced"
TOKEN = os.environ.get("HF_TOKEN", "").strip()

MODELS_DIR.mkdir(parents=True, exist_ok=True)
PRESETS_DIR.mkdir(parents=True, exist_ok=True)

PRESET_MAP = {
    "general": "bartowski/Llama-3.1-8B-Instruct-GGUF",
    "coding": "bartowski/Qwen2.5-Coder-7B-Instruct-GGUF",
    "roleplay": "bartowski/Nous-Hermes-3-Llama-3.1-8B-GGUF",
    "small": "bartowski/Phi-3.5-mini-instruct-GGUF",
    "balanced": "bartowski/Llama-3.1-8B-Instruct-GGUF",
}

# Presets are intentionally conservative: they give users useful starter models
# without forcing them to hand-pick filenames or quantization strings.
PRESET_DEFAULTS = {
    "balanced": ["general", "coding"],
    "roleplay": ["roleplay"],
    "coding": ["coding"],
    "general": ["general"],
    "small": ["small"],
}

def headers():
    hdrs = {"User-Agent": "RunPod-KoboldCPP-ModelBootstrap"}
    if TOKEN:
        hdrs["Authorization"] = f"Bearer {TOKEN}"
    return hdrs


def fetch_json(url: str):
    req = urllib.request.Request(url, headers=headers())
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.load(resp)


def sanitize(name: str) -> str:
    return "".join(ch if ch.isalnum() or ch in ("-", "_", ".") else "_" for ch in name)


def parse_entries(raw: str):
    entries = []
    for chunk in raw.split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        parts = [p.strip() for p in chunk.split("|")]
        repo = parts[0]
        filename = parts[1] if len(parts) > 1 and parts[1] else ""
        alias = parts[2] if len(parts) > 2 and parts[2] else sanitize(repo.split("/")[-1])
        entries.append({"repo": repo, "filename": filename, "alias": alias})
    return entries


def preset_entries():
    raw = HF_MODEL_PRESETS.strip()
    if not raw:
        raw = ",".join(PRESET_DEFAULTS.get(KCPP_PRESET, [KCPP_PRESET]))
    preset_names = [p.strip() for p in raw.split(",") if p.strip()]
    if not preset_names:
        preset_names = ["balanced"]
    entries = []
    for preset in preset_names:
        repo = PRESET_MAP.get(preset, preset)
        entries.append({"repo": repo, "filename": "", "alias": preset})
    return entries


def repo_files(repo: str):
    api = f"https://huggingface.co/api/models/{repo}"
    data = fetch_json(api)
    siblings = data.get("siblings", []) or []
    return data, siblings


def choose_gguf_file(siblings, preferred_quant: str):
    quant_tokens = []
    if preferred_quant:
        quant_tokens.append(preferred_quant)
    quant_tokens.extend(["Q4_K_M", "Q4_K_S", "Q5_K_M", "Q5_K_S", "Q6_K", "Q8_0", "IQ4_XS"])

    candidates = []
    for item in siblings:
        name = item.get("rfilename") or item.get("name") or ""
        if not name.lower().endswith(".gguf"):
            continue
        size = int(item.get("size") or 0)
        score = 0
        lower = name.lower()
        if "qwen" in lower:
            score += 3
        if "coder" in lower or "instruct" in lower:
            score += 2
        for idx, token in enumerate(quant_tokens):
            if token.lower() in lower:
                score += 100 - idx
                break
        candidates.append((score, size, name))

    if not candidates:
        return ""

    candidates.sort(key=lambda row: (-row[0], row[1], row[2].lower()))
    return candidates[0][2]


def download_file(repo: str, filename: str, target: pathlib.Path):
    url = f"https://huggingface.co/{repo}/resolve/main/{filename}?download=1"
    req = urllib.request.Request(url, headers=headers())
    with urllib.request.urlopen(req, timeout=1200) as resp, target.open("wb") as fh:
        shutil.copyfileobj(resp, fh)


def write_link(alias: str, real_path: pathlib.Path):
    link = PRESETS_DIR / f"{sanitize(alias)}.gguf"
    if link.exists() or link.is_symlink():
        link.unlink()
    link.symlink_to(real_path)
    return link


def download_one(entry):
    repo = entry["repo"]
    desired_filename = entry["filename"]
    alias = entry["alias"]
    data, siblings = repo_files(repo)

    if desired_filename:
        filename = desired_filename
    else:
        filename = choose_gguf_file(siblings, PREFERRED_QUANT)
        if not filename:
            raise SystemExit(f"no GGUF file discovered in {repo}")

    repo_dir = MODELS_DIR / sanitize(repo.replace("/", "--"))
    repo_dir.mkdir(parents=True, exist_ok=True)
    target = repo_dir / filename

    if not target.exists():
        download_file(repo, filename, target)

    link = write_link(alias, target)
    return {
        "repo": repo,
        "filename": filename,
        "alias": alias,
        "path": str(target),
        "link": str(link),
        "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
        "size": target.stat().st_size,
        "downloaded_at": datetime.now(timezone.utc).isoformat(),
    }

entries = []
if HF_MODEL_LIST:
    entries.extend(parse_entries(HF_MODEL_LIST))
else:
    entries.extend(preset_entries())

results = []
for entry in entries:
    try:
        results.append(download_one(entry))
    except Exception as exc:
        results.append({"repo": entry["repo"], "alias": entry["alias"], "error": str(exc)})

manifest = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "preset": KCPP_PRESET,
    "preferred_quantization": PREFERRED_QUANT,
    "entries": results,
}
MANIFEST_FILE.write_text(json.dumps(manifest, indent=2, sort_keys=True))

# The first successfully downloaded preset becomes the default model.
default_model = ""
for result in results:
    if "path" in result:
        default_model = result["path"]
        break
if default_model:
    default_link = PRESETS_DIR / "default.gguf"
    if default_link.exists() or default_link.is_symlink():
        default_link.unlink()
    default_link.symlink_to(default_model)

MARKER_FILE.write_text(json.dumps({"complete": True, "generated_at": datetime.now(timezone.utc).isoformat()}, indent=2))
PY

printf '[%s] [models] bootstrap complete\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" | tee -a "$HEALTH_LOG_FILE"
