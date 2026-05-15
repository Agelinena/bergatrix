FROM python:3.12-slim AS base

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    curl \
    git \
    nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Configura yt-dlp globalmente para usar Node.js como motor JS
# (YouTube exige execução de JS para desafios bot-detection; por padrão
#  o yt-dlp só habilita Deno — Node.js precisa ser explicitamente ativado)
RUN echo "--js-engine nodejs" > /etc/yt-dlp.conf

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
