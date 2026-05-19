FROM python:3.12-slim AS base

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    curl \
    git \
    nodejs \
    unzip \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install deno — yt-dlp's modern YouTube extractor requires a JavaScript
# runtime to solve player challenges.  Without it, yt-dlp logs:
#   "No supported JavaScript runtime could be found"
# and falls back to limited formats that get rate-limited (HTTP 429)
# much faster than the full-format path.
RUN curl -fsSL https://github.com/denoland/deno/releases/latest/download/deno-x86_64-unknown-linux-gnu.zip -o /tmp/deno.zip \
    && unzip /tmp/deno.zip -d /usr/local/bin \
    && rm /tmp/deno.zip \
    && chmod +x /usr/local/bin/deno \
    && deno --version

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM base AS development
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
COPY . .
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]

FROM base AS production
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
COPY . .

RUN mkdir -p /data/music/permanent /data/music/cache

# Roda migrations antes de subir o servidor
# Single worker: asyncio.Semaphore e asyncio.Lock precisam ser compartilhados
# no mesmo processo. Com múltiplos workers, cada processo tem sua própria
# instância — o semáforo do yt-dlp deixa de funcionar e o lock do deemix causa
# race conditions. Um único worker com workers assíncronos internos (stream +
# background) é suficiente para a carga esperada.
CMD ["sh", "-c", "alembic upgrade head && uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 1"]
