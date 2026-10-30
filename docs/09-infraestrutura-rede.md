# Documentação da Infraestrutura: Edge Node L4 & Homelab

## Visão Geral
Esta arquitetura utiliza uma **VPS na Hostinger (localizada em São Paulo)** atuando estritamente como um "Edge Node" na Camada 4 (Transporte). Ela filtra, estabiliza e redireciona o tráfego de forma transparente e segura via túnel WireGuard para o **Servidor Físico Principal (Homelab, localizado em casa)**, onde ocorre o processamento real, terminação SSL e proteção a nível de aplicação.

---

## 1. Edge Node: VPS Hostinger (São Paulo)
A VPS funciona como um escudo cego. Ela não possui certificados SSL, não processa HTTP e consome recursos mínimos.

* **Filtro GeoIP (`nftables`)**: 
  * Regras em nível de kernel configuradas para fazer *drop* silencioso de qualquer pacote nas portas TCP 80 e 443 que não venha de um IP registrado no Brasil.
  * O tráfego bloqueado não gera resposta (ex: `ERR_TUNNEL_CONNECTION_FAILED` para VPNs internacionais), tornando os serviços "invisíveis" para scanners estrangeiros e bots.
* **Anti-Bufferbloat e QoS (`tc` + CAKE)**:
  * Implementado na interface pública (`eth0`) com limite aproximado de 240Mbit.
  * Garante que picos de tráfego (como uploads pesados no Immich) não saturem a placa de rede da VPS, mantendo a latência do túnel cravada e evitando engasgos na conexão.
* **Encaminhamento Transparente (`HAProxy`)**:
  * Escuta nas portas 80 e 443 em modo `tcp`.
  * Utiliza a flag `send-proxy-v2` para envelopar os pacotes, enviando o IP real do cliente (Proxy Protocol) para o servidor local.
  * Repassa o tráfego diretamente para o IP local do homelab através do túnel.

---

## 2. A Ponte: Túnel WireGuard
* Conexão criptografada ponto a ponto conectando a VPS em SP ao servidor físico em casa.
* **IP da VPS no túnel:** `10.100.0.1`
* **IP do Peer (Homelab) permitido:** `10.100.0.2` e acesso roteado para a rede local (`192.168.10.11`).

---

## 3. Core: Servidor Físico (Homelab em Casa)
Toda a inteligência de aplicação, dados e processamento ficam retidos na rede local, nunca expostos diretamente à internet.

* **Terminação TLS e Roteamento Ingress (`Traefik`)**:
  * Escuta no IP local (`192.168.10.11`).
  * Configurado com `proxyProtocol` e `trustedIPs: ["10.100.0.1/32"]` (restrito ao IP da VPS no túnel).
  * Lê o pacote do HAProxy, extrai o IP real do cliente, aplica os certificados SSL (Let's Encrypt / deSEC) e distribui o tráfego para os containers corretos (ex: Drop, Immich).
* **Proteção de Aplicação (`CrowdSec`)**:
  * Graças ao Proxy Protocol, o CrowdSec lê os IPs verdadeiros dos clientes nos logs do Traefik.
  * Se um IP brasileiro tentar força bruta ou escaneamento de vulnerabilidades, o CrowdSec bane o IP real do atacante dentro da rede local, sem penalizar ou banir o IP do túnel da VPS.

---

## 4. Fluxo de Roteamento (Passo a Passo)

1. **Cliente no Brasil** acessa `https://drop.daberga.com`.
2. O DNS aponta para o IP público da **VPS Hostinger (SP)**.
3. O pacote chega na interface `eth0` da VPS. O **`nftables`** verifica o IP de origem. Sendo do Brasil, o pacote é aceito.
4. O tráfego entra no **HAProxy**. O HAProxy empacota a conexão original (adicionando o IP real do cliente via *Proxy Protocol*) e encaminha para o backend `192.168.10.11:443` usando o modo TCP.
5. O pacote é roteado para a interface **`wg0` (WireGuard)**, criptografado e enviado pelo túnel de SP até a sua casa.
6. O **Servidor Físico (Casa)** recebe o pacote na porta 443 do **Traefik**.
7. O **Traefik** verifica que a origem é de um IP confiável (`10.100.0.1`), desembrulha o Proxy Protocol, registra o IP real do cliente, descriptografa o TLS e entrega a requisição HTTP limpa para o container final.

---

## 5. Resumo das Proteções (Camadas de Segurança)
* **Camada 3/4 (Borda):** Bloqueio geográfico total de IPs não-brasileiros. Sem portas expostas além de 80, 443, 2222 (SSH restrito) e 51820 (WireGuard).
* **Ocultamento (Stealth):** Atacantes internacionais recebem *Timeout* silencioso em vez de erro *403 Forbidden*, mascarando a existência do servidor.
* **Segurança de Trânsito:** Todo o tráfego entre SP e a Casa viaja sob criptografia robusta de chave assimétrica (WireGuard).
* **Camada 7 (Aplicação):** Proteção inteligente (IPS/IDS) via CrowdSec baseada em comportamento no servidor local, bloqueando anomalias de IPs brasileiros.
* **Privilégio Mínimo:** Traefik só aceita cabeçalhos Proxy forjados se vierem estritamente do IP autorizado do túnel WireGuard (`/32`), prevenindo ataques de *IP Spoofing* a partir da rede local ou de containers comprometidos.
