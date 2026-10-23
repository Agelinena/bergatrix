# Drop: relay cego entre dois navegadores. Sem disco, sem conta.

FROM python:3.13.17-slim-trixie AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
COPY requirements.txt /tmp/requirements.txt
# Só wheels com o hash do requirements.txt: nada compilado nem trocado no caminho.
RUN python -m venv /venv \
    && /venv/bin/pip install --require-hashes --only-binary=:all: -r /tmp/requirements.txt \
    && /venv/bin/pip uninstall -y pip

FROM python:3.13.17-slim-trixie
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/venv/bin:$PATH
# Sem pip na imagem final: um container invadido não instala nada.
RUN python -m pip uninstall -y pip \
    && rm -rf /usr/local/lib/python3.13/ensurepip
COPY --from=build /venv /venv
# Código do root e só leitura para o usuário do app.
COPY app/ /app/
WORKDIR /app

USER 10001:10001
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2)"]

# websockets-sansio: o envio espera o socket esvaziar e a leitura pausa a cada
# mensagem, então a memória por conexão fica em um frame (66 KiB) e buffers.
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8000", \
     "--ws", "websockets-sansio", "--ws-max-size", "67584", \
     "--ws-ping-interval", "20", "--ws-ping-timeout", "20", \
     "--limit-concurrency", "600", "--timeout-keep-alive", "5", \
     "--no-access-log", "--no-server-header", "--no-date-header"]
