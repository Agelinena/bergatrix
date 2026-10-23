# Transcriptor: API e interface web (sem GPU). Contexto de build: a pasta da stack.

FROM python:3.13.17-slim-trixie AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
COPY api/requirements.txt /tmp/requirements.txt
RUN python -m venv /venv \
    && /venv/bin/pip install --require-hashes --only-binary=:all: -r /tmp/requirements.txt \
    && /venv/bin/pip uninstall -y pip

FROM python:3.13.17-slim-trixie
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/venv/bin:$PATH
RUN python -m pip uninstall -y pip \
    && rm -rf /usr/local/lib/python3.13/ensurepip
COPY --from=build /venv /venv
WORKDIR /code
COPY app ./app

USER 1000:1000
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3)"]

CMD ["uvicorn", "app.api.main:app", "--host", "0.0.0.0", "--port", "8000", \
     "--proxy-headers", "--forwarded-allow-ips", "*", "--no-server-header", "--timeout-keep-alive", "10"]
