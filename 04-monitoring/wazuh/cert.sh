cd ./config/wazuh_indexer_ssl_certs

# CA raiz
openssl genrsa -out root-ca.key 2048
openssl req -x509 -new -nodes -key root-ca.key -sha256 -days 3650 \
  -subj "/CN=Wazuh Root CA" -out root-ca.pem

# Função para gerar cert com SAN
gen_cert() {
  NAME=$1
  DNS=$2
  openssl genrsa -out ${NAME}-key.pem 2048
  openssl req -new -key ${NAME}-key.pem \
    -subj "/CN=${DNS}" \
    -out ${NAME}.csr
  openssl x509 -req -in ${NAME}.csr -CA root-ca.pem -CAkey root-ca.key \
    -CAcreateserial -out ${NAME}.pem -days 3650 -sha256 \
    -extfile <(printf "subjectAltName=IP:127.0.0.1,DNS:${DNS}")
  rm ${NAME}.csr
}

# Gera cada certificado
gen_cert wazuh.indexer wazuh.indexer
gen_cert wazuh.manager wazuh.manager
gen_cert wazuh.dashboard wazuh.dashboard

# Admin (sem SAN necessário)
openssl genrsa -out admin-key.pem 2048
openssl req -new -key admin-key.pem -subj "/CN=admin" -out admin.csr
openssl x509 -req -in admin.csr -CA root-ca.pem -CAkey root-ca.key \
  -CAcreateserial -out admin.pem -days 3650 -sha256
rm admin.csr

# Copia root-ca para o manager também
cp root-ca.pem root-ca-manager.pem
cp root-ca.key root-ca-manager.key

cd -
