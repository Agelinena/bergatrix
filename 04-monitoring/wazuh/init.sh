#!/bin/bash

# Carrega variáveis do .env
if [ -f .env ]; then
  export $(cat .env | grep -v '#' | awk '/=/ {print $1}')
else
  echo "Arquivo .env não encontrado!"
  exit 1
fi

echo "🚀 Criando estrutura de diretórios em $WAZUH_DATA_DIR..."

# Cria as pastas de persistência dos containers
mkdir -p $WAZUH_DATA_DIR/wazuh_manager/{api_configuration,etc,logs,queue,var_multigroups,integrations,active_response,agentless,wodles}
mkdir -p $WAZUH_DATA_DIR/filebeat/{etc,var}
mkdir -p $WAZUH_DATA_DIR/wazuh_indexer/data
mkdir -p $WAZUH_DATA_DIR/wazuh_dashboard/{config,custom}

# Cria a pasta de configurações
mkdir -p $WAZUH_DATA_DIR/config/wazuh_indexer_ssl_certs

# Se você tem a pasta config original localmente, ele copia tudo para o storage
if [ -d "./config" ]; then
    echo "📂 Copiando arquivos de configuração base para o storage..."
    cp -rn ./config/* $WAZUH_DATA_DIR/config/
fi

echo "🔐 Gerando os certificados SSL..."
# O docker compose do gerador é chamado antes de aplicar o chmod
docker compose -f generate-indexer-certs.yml up

echo "🔧 Ajustando permissões oficiais das pastas e arquivos (Host -> Container)..."

# Permissões do Manager (Usuário interno: wazuh - 999:999)
chown -R 999:999 $WAZUH_DATA_DIR/wazuh_manager

# Permissões do Indexer e Dashboard (Usuário interno - 1000:1000)
chown -R 1000:1000 $WAZUH_DATA_DIR/wazuh_indexer
chown -R 1000:1000 $WAZUH_DATA_DIR/wazuh_dashboard

# Permissões básicas para Filebeat (Root - 0:0)
chown -R 0:0 $WAZUH_DATA_DIR/filebeat

# Permissões de segurança para os certificados SSL gerados (leitura para não-root)
# (O || true evita que o script trave caso os arquivos não tenham sido gerados)
chmod 644 $WAZUH_DATA_DIR/config/wazuh_indexer_ssl_certs/*.pem 2>/dev/null || true

echo "✅ Inicialização concluída! Pode iniciar o ambiente com: docker compose up -d"