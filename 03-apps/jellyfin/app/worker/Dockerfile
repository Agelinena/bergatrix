FROM python:3.11-slim

# ffmpeg para extração de streams de legenda e ferramentas para baixar alass
RUN apt-get update && apt-get install -y \
    ffmpeg \
    wget \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Instalar alass (usado para sincronizar legendas)
RUN wget -qO alass.tar.gz https://github.com/kaegi/alass/releases/download/v2.0.0/alass-linux64.tar.gz \
    && tar -xzf alass.tar.gz \
    && mv alass-linux64/alass /usr/local/bin/alass \
    && chmod +x /usr/local/bin/alass \
    && rm -rf alass.tar.gz alass-linux64

WORKDIR /app

# Dependências Python
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Código da aplicação
COPY . .

ENV PYTHONUNBUFFERED=1

CMD ["python", "main.py"]
