FROM python:3.11-slim

# Dependências do sistema: ffmpeg, git, tesseract-ocr e idiomas
RUN apt-get update && apt-get install -y \
    ffmpeg \
    git \
    tesseract-ocr \
    tesseract-ocr-por \
    tesseract-ocr-eng \
    tesseract-ocr-spa \
    tesseract-ocr-fra \
    tesseract-ocr-deu \
    tesseract-ocr-ita \
    libtesseract-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Dependências Python
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Código da aplicação
COPY . .

ENV PYTHONUNBUFFERED=1

CMD ["python", "main.py"]
