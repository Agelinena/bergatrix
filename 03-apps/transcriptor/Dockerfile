# Use uma imagem base do NVIDIA CUDA para ter acesso à GPU
FROM nvidia/cuda:12.1.0-cudnn8-runtime-ubuntu22.04

# Evita que pacotes peçam inputs interativos
ENV DEBIAN_FRONTEND=noninteractive

# Instala dependências do sistema
RUN apt-get update && apt-get install -y \
    python3.10 \
    python3-pip \
    git \
    tzdata \
    ffmpeg \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# <<< MUDANÇA AQUI: Garante a versão mais recente do yt-dlp >>>
RUN pip install --upgrade yt-dlp

# Define o diretório de trabalho
WORKDIR /app

# Adiciona o diretório da aplicação ao PYTHONPATH
ENV PYTHONPATH /app

# Instala a versão correta do PyTorch para CUDA 12.1
RUN pip install torch --index-url https://download.pytorch.org/whl/cu121

# Copia o arquivo de dependências e instala o resto
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copia o código da aplicação
COPY ./app /app

# Expõe a porta
EXPOSE 8000

# Arruma fuso horario:
RUN ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime