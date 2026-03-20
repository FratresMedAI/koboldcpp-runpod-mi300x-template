FROM runpod/pytorch:2.4.0-py3.10-rocm6.1.0-ubuntu22.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    ROCM_PATH=/opt/rocm \
    PATH=/opt/rocm/bin:/opt/conda/bin:${PATH} \
    LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib64:${LD_LIBRARY_PATH} \
    KCPP_HOME=/opt/koboldcpp \
    KCPP_BIN_DIR=/opt/koboldcpp/bin \
    KCPP_RELEASE_DIR=/opt/koboldcpp/releases \
    KCPP_MODEL_DIR=/workspace/models \
    KCPP_CACHE_DIR=/workspace/cache \
    KCPP_LOG_DIR=/logs \
    KCPP_STATUS_FILE=/logs/koboldcpp-status.json \
    HEALTH_LOG_FILE=/logs/health.log \
    HEALTH_PORT=8080 \
    KCPP_PORT=5001 \
    KCPP_HOST=0.0.0.0 \
    KCPP_BACKEND=auto \
    KCPP_PRESET=balanced \
    KCPP_CONTEXT_SIZE=8192 \
    KCPP_GPU_LAYERS=999 \
    KCPP_THREADS=0 \
    KCPP_BLAS_THREADS=0 \
    KCPP_EXTRA_ARGS= \
    AUTO_HEAL=1 \
    AUTO_DOWNLOAD_MODELS=1 \
    ALLOW_CPU_FALLBACK=0 \
    KCPP_ENABLE_SOURCE_REPAIR=0 \
    DISCORD_WEBHOOK_URL= \
    HF_MODEL_QUANTIZATION=Q4_K_M \
    HF_MODEL_PRESETS= \
    HF_MODEL_LIST= \
    FORCE_MODEL_DOWNLOAD=0

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      procps \
      python3 \
      python3-pip \
 && python3 -m pip install --no-cache-dir --break-system-packages runpod \
 && rm -rf /var/lib/apt/lists/*

RUN if ! id -u runpod >/dev/null 2>&1; then useradd -m -s /bin/bash runpod; fi \
 && mkdir -p /opt/koboldcpp/bin /opt/koboldcpp/releases /workspace/models /workspace/cache /logs \
 && chown -R runpod:runpod /opt/koboldcpp /workspace /logs

COPY --chown=runpod:runpod entrypoint.sh gpu-detect.sh auto-patch.sh health-check.sh models-download.sh handler.py /opt/koboldcpp/

RUN chmod 0755 /opt/koboldcpp/*.sh

USER runpod
WORKDIR /workspace

EXPOSE 5001 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
  CMD /opt/koboldcpp/health-check.sh probe

ENTRYPOINT ["/opt/koboldcpp/entrypoint.sh"]
CMD []
