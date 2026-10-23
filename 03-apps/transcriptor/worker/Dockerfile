# Transcriptor: worker com GPU. Contexto de build: a pasta da stack.
#
# CUDA 12 + cuDNN 8 com CTranslate2 4.4.0: a combinação que roda na GTX 1060
# (Pascal). Não suba para CUDA 13 nem para o CTranslate2 4.5+ (cuDNN 9) sem
# testar na GPU: o CUDA 13 não suporta Pascal.

FROM denoland/deno:bin-2.9.8 AS deno

FROM nvidia/cuda:12.2.2-cudnn8-runtime-ubuntu22.04
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    HF_HUB_DISABLE_TELEMETRY=1 \
    PATH=/venv/bin:$PATH

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3.10 python3.10-venv ffmpeg ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

# Deno: o yt-dlp precisa de um runtime JavaScript para extrair do YouTube.
COPY --from=deno /deno /usr/local/bin/deno

COPY worker/requirements.txt /tmp/requirements.txt
RUN python3.10 -m venv /venv \
    && /venv/bin/pip install --require-hashes -r /tmp/requirements.txt \
    && /venv/bin/pip uninstall -y pip \
    && rm /tmp/requirements.txt

WORKDIR /code
COPY app ./app

USER 1000:1000

HEALTHCHECK --interval=30s --timeout=5s --start-period=30m --retries=3 \
    CMD ["python", "-c", "import os, sys, time; sys.exit(0 if time.time() - os.path.getmtime('/tmp/healthy') < 120 else 1)"]

CMD ["python", "-m", "app.worker.main"]
