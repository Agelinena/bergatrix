# Plano: novo modelo de acesso (Traefik + Authentik)

Plano para trocar o modelo atual de três rotas (forward-auth do Authentik, acesso direto por IP e bypass em `/api-access-bypass`) por um modelo em que cada serviço tem **um único jeito de entrar**, escolhido conforme o que o app suporta. A migração é gradual, um serviço por vez. Atualize a coluna "Estado" conforme avançar.

## Os modelos de destino

| Modelo | Quando usar | Como fica no Traefik |
|---|---|---|
| **A. OIDC** | O app suporta OpenID Connect | Uma rota com `crowdsec-bouncer`. O app faz o login pelo Authentik. |
| **B. LDAP** | Sem OIDC, mas aceita LDAP. Bom para apps com cliente de TV ou celular. | Uma rota com `crowdsec-bouncer`. O app consulta o outpost LDAP ([guia](guias/autenticacao-ldap.md)). |
| **C. Forward-auth** | Interface web sem login próprio, ou com login fraco, e **sem** clientes de API ou celular | Uma rota com `crowdsec-bouncer` e `authentik@file` |
| **D. Só rede local/VPN** | Ferramentas de administração e APIs internas | Uma rota com `internal-only@file` (ou `lan-only@file`) |
| **E. Público com login próprio** | O app tem autenticação forte e clientes que não passam por forward-auth, ou é público por natureza | Uma rota com `crowdsec-bouncer` |
| **F. Sem rota** | Serviço só usado por outros containers | Sem labels do Traefik e fora da `bergatrix-proxy` |

O que deixa de existir: a rota `-direct` por IP fixo, a rota `-bypass` e o middleware `api-access-bypass`.

## Mapa por serviço

| Stack | Serviço | Endereço | Hoje | Destino | Observações | Estado |
|---|---|---|---|---|---|---|
| traefik | painel | `traefik` | D + basic auth | **D** (+C opcional) | O basic auth pode virar forward-auth para um grupo de admins | – |
| authentik | server | `authentik` | Público; `/if/admin` em D | **E**; admin em **D** | O login precisa ser público, para o OIDC funcionar de fora | – |
| authentik | server | `auth` | Público (callback) | **Remover** ou unificar | Host duplicado, provável sobra da migração de domínio | – |
| authentik | ldap (outpost) | – | F, na `bergatrix-proxy` | **F** em rede própria | Mover para a rede `bergatrix-ldap` | – |
| bitwarden | vaultwarden | `bitwarden` | 3 rotas + 3 rotas de WebSocket | **E** (+A opcional) | As extensões e os apps precisam da API sem forward-auth. A proteção é a senha mestra com 2FA. `/admin` em D. Versões recentes têm SSO por OIDC, mas a senha mestra continua necessária. O WebSocket agora fica na porta 80; as rotas `-ws-*` para a 3012 devem estar obsoletas. | – |
| crowdsec | crowdsec | – | F | **F** | Fala com o Traefik pela rede | – |
| cloudbeaver | cloudbeaver | `db` | 3 rotas | **Remover** ou C+D | Não alcança nenhum banco desde que o Postgres global saiu. SSO e LDAP só nas edições pagas. | – |
| bergalink | api | `bergalink` | A | **A** | Já nasce no modelo de destino | ✓ |
| bergastream | web/api | `bergastream` | 3 rotas + JWT próprio (login duplo na web) | **E** agora, **A** depois | Primeiro, tirar o forward-auth e o bypass: o app já descobre o prefixo sozinho e passa a usar a raiz. O OIDC exige mudar o backend e o app Flutter, como no Bergalink. | – |
| bergastream | lidarr | `lidarr` | D | **D** | Tem login próprio. Sair da `bergatrix-proxy` para falar com o SABnzbd e o Prowlarr por uma rede de mídia compartilhada. | – |
| bergastream | deemix, pot, worker, db, redis | – | F | **F** | – | ✓ |
| drop | drop | `drop` | E (rate limit) | **E** | Público por natureza (cifra de ponta a ponta, sem contas). Acrescentar `crowdsec-bouncer`. | – |
| homeassistant | homeassistant | `ha` | 3 rotas (bypass para o app Companion) | **E** (+A opcional) | O app Companion fala direto com a API. Proteção: login do HA com MFA. Configurar `trusted_proxies`. Não há OIDC nativo; existe uma integração da comunidade (`hass-oidc-auth`). | – |
| jellyfin | jellyfin | `jellyflix` | E, sem CrowdSec | **B** | LDAP feito. Falta o `crowdsec-bouncer`. | Em andamento |
| jellyfin | catalogo (Seerr) | `catalogo` | 2 rotas (forward-auth + IP) | **E** | O login do Seerr é pela conta do Jellyfin, que agora usa LDAP: as senhas do Authentik valem nos dois. Usar OIDC se a versão suportar. | – |
| jellyfin | sonarr, radarr, prowlarr, bazarr, sabnzbd, qbittorrent | um por serviço | D | **D** | Têm login próprio. Para usar de fora: VPN ou C. Corrigir as labels incompletas do radarr. | – |
| jellyfin | legendarr-web | `legendarr` | D | **D** (+C) | Sem login nenhum, e o webhook é aberto | – |
| jellyfin | flaresolverr, torrent-indexer-br | um por serviço | D | **F** | Só o Prowlarr usa. Tirar a rota. | – |
| jellyfin | recyclarr, optimizer, legendarr-worker | – | F | **F** | O worker sai da `bergatrix-proxy` (usa o Ollama pela rede de IA) | – |
| litellm | litellm | `llm` | D | **D** | A API usa chaves próprias. A interface tem SSO grátis até 5 usuários (opcional A). | – |
| litellm | litellm-updater | – | F, na `bergatrix-proxy` | **F** | Sair da `bergatrix-proxy` | – |
| n8n | n8n | `n8n` | 2 rotas (forward-auth + IP) | Editor em **D** ou **C**; `/webhook*` em **E** | OIDC, SAML e LDAP são pagos no n8n. Os webhooks externos não passam por forward-auth, então precisam de uma rota própria. | – |
| openuiweb | open-webui | `chat` | 2 rotas (forward-auth + IP) | **A** | OIDC nativo, só com variáveis de ambiente (`OAUTH_*`, `OPENID_PROVIDER_URL`). É o melhor piloto de OIDC. | – |
| openuiweb | ollama | – | F, na `bergatrix-proxy` | **F** em rede de IA | Usado pelo Open WebUI, pelo LiteLLM e pelo Legendarr | – |
| transcriptor | transcriptor | `transcriptor` | 2 rotas (forward-auth + IP) | **A** (código próprio); antes, **C** na interface | A interface não tem login (só um cookie assinado). A API v1 usa `X-API-Key` e precisaria de rota sem forward-auth. | – |
| homepage | homepage | `homepage` | D | **D** (+C) | Sem login | – |
| wazuh | dashboard | `wazuh` | D | **D** (+A opcional) | Aceita OIDC pelo plugin de segurança do OpenSearch, mas é trabalhoso | – |
| wazuh | manager | portas 1514/1515/514/55000 | Portas publicadas | Revisar | A 55000 (API) não precisa ficar exposta na rede inteira | – |
| *infra* | Proxmox | (IP local) | Login local | **A** + D | O Proxmox tem realm OpenID Connect nativo | – |
| *infra* | OpenMediaVault | (IP local) | Login local | **D** | Só rede local. Interface em PHP: manter sempre atualizado. | – |

## Redes

| Rede | Hoje | Destino |
|---|---|---|
| `bergatrix-proxy` | Traefik e quase todos os containers, inclusive os que não têm rota | Só o Traefik e os serviços **com rota** |
| `bergatrix-ldap` (nova) | – | Outpost LDAP e os apps que usam LDAP (Jellyfin) |
| `bergatrix-ai` (nova) | – | Ollama, Open WebUI, LiteLLM e o worker do Legendarr |
| `bergatrix-media` (nova, substitui `media-internal`) | `media-internal`, interna da stack jellyfin | Os *arr, SABnzbd e Prowlarr, e o Lidarr do bergastream |
| `<stack>-internal` | Bergastream, Bergalink, LiteLLM e Authentik | Bancos e serviços internos de cada stack (sem mudança) |

## Traefik (`dynamic.yml`)

| Item | Destino |
|---|---|
| `api-access-bypass` | Remover depois que nenhuma rota usar mais |
| Rotas `-direct` com `ClientIP` em ~10 composes | Remover. É o fim dos IPs fixos nas labels. |
| `internal-only` (3 IPs fixos) | Trocar por `lan-only` (a sub-rede) e a faixa da VPN, se houver |
| `authentik` (forward-auth) | Manter para o modelo C. Avaliar tirar `Authorization` de `authResponseHeaders`: ele já atrapalhou o login do Bergastream. |
| `public-auth` | Pode ser removido; usar `authentik@file` direto |
| `proxyProtocol` e `forwardedHeaders` (`10.100.0.1`) | Revisar junto com a decisão sobre o acesso externo (abaixo) |

## Decisões em aberto

1. **Acesso de fora às ferramentas do modelo D** (*arr, Homepage, painéis): pela VPN (WireGuard ou Tailscale), ou pelo forward-auth (C)? A VPN tira essas interfaces da internet de vez.
2. **Caminho do tráfego externo:** a configuração ainda espera um proxy em `10.100.0.1` com PROXY protocol, mas a VM nova não tem túnel. Confirmar como o tráfego de fora chega hoje.
3. **CloudBeaver:** remover a stack ou dar uma função para ela.
4. **Host `auth`:** confirmar se algo ainda usa e removê-lo.

## Ordem sugerida

Do menor para o maior risco. Cada passo é independente.

1. **Jellyfin:** acrescentar o `crowdsec-bouncer`. O LDAP já está feito.
2. **Redes:** tirar as rotas e o acesso à `bergatrix-proxy` dos serviços F (flaresolverr, torrent-indexer, ollama, litellm-updater, outpost LDAP) e criar as redes `bergatrix-ldap`, `bergatrix-ai` e `bergatrix-media`. Nada muda para quem usa.
3. **Open WebUI → OIDC**, o piloto de OIDC.
4. **Proxmox → realm OIDC.**
5. **Seerr:** tirar o forward-auth (o login passa a ser pelo Jellyfin com LDAP).
6. **Vaultwarden:** uma rota só, revisar o WebSocket, `/admin` em D.
7. **Home Assistant:** uma rota só, com `trusted_proxies` e MFA.
8. **Bergastream:** uma rota só, sem forward-auth nem bypass. O OIDC fica para depois, no código.
9. **n8n:** separar os webhooks (E) do editor (D ou C).
10. **Ferramentas de administração:** aplicar a decisão 1.
11. **`dynamic.yml`:** remover o `api-access-bypass` e os IPs fixos.
12. **Transcriptor e Bergastream → OIDC** no código, seguindo o Bergalink como modelo.
