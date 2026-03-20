"""RunPod Hub compatibility handler for the KoboldCPP MI300X template.

This handler is intentionally lightweight: it gives the repository a real
serverless-compatible entry point for Hub validation and optional load-balanced
conversion, while the container runtime itself remains pod-first.
"""

from __future__ import annotations

import os
from datetime import datetime, timezone

import runpod


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _payload(action: str, event: dict) -> dict:
    return {
        "action": action,
        "status": "ok",
        "timestamp": _now(),
        "backend": os.getenv("KCPP_BACKEND", "auto"),
        "preset": os.getenv("KCPP_PRESET", "balanced"),
        "model": os.getenv("KCPP_MODEL", ""),
        "health_port": int(os.getenv("HEALTH_PORT", "8080")),
        "kcpp_port": int(os.getenv("KCPP_PORT", "5001")),
        "input": event,
    }


def handler(event: dict) -> dict:
    action = str((event or {}).get("action", "status")).lower().strip()

    if action in {"health", "status", "metadata"}:
        return {"status": "COMPLETED", "output": _payload(action, event)}

    return {
        "status": "COMPLETED",
        "output": {
            "status": "ok",
            "action": action,
            "message": "This template is pod-first; use the KoboldCPP UI on port 5001 for interactive chat.",
            "timestamp": _now(),
        },
    }


if __name__ == "__main__":
    runpod.serverless.start({"handler": handler})
