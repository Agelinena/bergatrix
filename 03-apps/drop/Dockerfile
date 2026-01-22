FROM python:3.11-slim

WORKDIR /app

# Copia o requirements da pasta 'app' para o container
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copia todo o resto da pasta 'app' para o workdir do container
COPY app/ .

# Expõe a porta e inicia o uvicorn
EXPOSE 8000
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8000"]
