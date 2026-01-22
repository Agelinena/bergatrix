FROM python:3.9-slim

ENV PYTHONUNBUFFERED=1

WORKDIR /app

RUN pip install --no-cache-dir flask requests beautifulsoup4

COPY . .

CMD ["python", "app.py"]
