FROM python:3.11-slim

# ffmpeg para extração de streams de legenda; wget para baixar o alass
RUN apt-get update && apt-get install -y \
    ffmpeg \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Instalar alass (usado para sincronizar legendas)
RUN wget -qO /usr/local/bin/alass https://github.com/kaegi/alass/releases/download/v2.0.0/alass-linux64 \
    && chmod +x /usr/local/bin/alass

WORKDIR /app

# Dependências Python
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Código da aplicação
COPY . .

ENV PYTHONUNBUFFERED=1

CMD ["python", "main.py"]
