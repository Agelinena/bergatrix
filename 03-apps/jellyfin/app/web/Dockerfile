FROM python:3.10-slim

WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Run the web app
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
