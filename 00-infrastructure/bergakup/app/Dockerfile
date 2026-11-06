# Bergakup: interface (React) e API (FastAPI) num container só.
# Contexto de build: a pasta da stack (00-infrastructure/bergakup).

FROM node:22.11.0-alpine AS web
WORKDIR /web
COPY web/package.json web/package-lock.json* ./
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi
COPY web/ ./
RUN npm run build

FROM python:3.13.17-slim-trixie AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
COPY app/requirements.txt /tmp/requirements.txt
RUN python -m venv /venv \
    && /venv/bin/pip install --only-binary=:all: -r /tmp/requirements.txt \
    && /venv/bin/pip uninstall -y pip

FROM python:3.13.17-slim-trixie
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/venv/bin:$PATH
RUN python -m pip uninstall -y pip \
    && rm -rf /usr/local/lib/python3.13/ensurepip
COPY --from=build /venv /venv
WORKDIR /code
COPY app/bergakup ./bergakup
COPY --from=web /web/dist ./static

USER 1000:1000
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3)"]

CMD ["uvicorn", "bergakup.main:app", "--host", "0.0.0.0", "--port", "8000", \
     "--proxy-headers", "--forwarded-allow-ips", "*", "--no-server-header", "--timeout-keep-alive", "65"]
