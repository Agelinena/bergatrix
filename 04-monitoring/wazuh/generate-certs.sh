#!/bin/bash

set -e

echo "Iniciando geração dos certificados do Wazuh..."

# Cria diretório de certs local se não existir
mkdir -p ./certs

# Arquivo de configuração base para o gerador de certs
cat > ./config/certs.yml << 'EOF'
nodes:
  indexer:
    - name: node-1
      ip: 127.0.0.1
  server:
    - name: wazuh-1
      ip: 127.0.0.1
  dashboard:
    - name: dashboard
      ip: 127.0.0.1
EOF

echo "Rodando gerador de certificados (isso pode levar alguns segundos)..."
docker run --rm \
  -v $(pwd)/certs:/certificates \
  -v $(pwd)/config/certs.yml:/config/certs.yml \
  wazuh/wazuh-certs-generator:0.0.2 \
  -A

echo "Ajustando permissões dos certificados gerados (sudo exigido)..."

sudo chown -R 1000:1000 ./certs
sudo chmod -R 500 ./certs
sudo chmod -R 400 ./certs/*

echo "✅ Certificados gerados com sucesso."
echo "Você já pode rodar: docker compose up -d"
