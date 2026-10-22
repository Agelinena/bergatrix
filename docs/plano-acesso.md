# Plano: novo modelo de acesso (Traefik + Authentik)

Plano para trocar o modelo atual de três rotas (forward-auth do Authentik, acesso direto por IP e bypass em `/api-access-bypass`) por um modelo em que **o Authentik é a porta de entrada de quase tudo**, inclusive de fora de casa, sem depender de VPN. Cada serviço tem uma única rota. A migração é gradual: atualize a coluna "Estado" conforme avançar.

## Decisões tomadas (outubro de 2026)

- **Login único pelo Authentik**, com 2FA, para todos os serviços que tiverem interface. A VPN fica só para a infraestrutura (Proxmox e OMV).
- **Público sem Authentik**: só o Drop, e os serviços que já têm login próprio forte e clientes que não passam por forward-auth (Vaultwarden, Home Assistant, Seerr).
- **Fim** das rotas `-direct` por IP fixo, da rota `-bypass` e do middleware `api-access-bypass`.

## Os modelos

| Modelo | Quando usar | Rota no Traefik |
|---|---|---|
| **A. SSO nativo (OIDC ou SAML)** | O app sabe falar com o Authentik sozinho | `crowdsec-bouncer` |
| **B. LDAP** | Sem OIDC, mas aceita LDAP e tem cliente de TV ou celular ([guia](guias/autenticacao-ldap.md)) | `crowdsec-bouncer` |
| **C. SSO na frente (forward-auth)** | Sem OIDC: o Authentik pede o login antes de deixar passar | `crowdsec-bouncer` + `authentik@file` |
| **D. Só rede local/VPN** | Infraestrutura crítica | `lan-only@file` |
| **E. Público com login próprio** | O app tem autenticação forte e clientes que não passam por forward-auth, ou é público por natureza | `crowdsec-bouncer` |
| **F. Sem rota** | Usado só por outros containers | Sem labels e fora da `bergatrix-proxy` |

Para quem usa, A, B e C dão o mesmo resultado: a tela do Authentik, o mesmo 2FA e uma sessão só. As diferenças entre eles:

- **A:** o app sabe quem é a pessoa e aplica as permissões dela.
- **B:** o app pede a senha do Authentik direto, sem tela de SSO.
- **C:** o Authentik só libera a passagem.
  - O app pode continuar pedindo o próprio login. Nos *arr dá para desligar isso, com `AuthenticationMethod=External`.
  - Apps de celular e clientes de API não passam pelo forward-auth. As chamadas entre containers não são afetadas, porque não passam pelo Traefik.

## Mapa por serviço

| Stack | Serviço | Endereço | Hoje | Destino | Observações | Estado |
|---|---|---|---|---|---|---|
| bergalink | api | `bergalink` | A | **A** (OIDC) | Modelo de referência | ✓ |
| openuiweb | open-webui | `chat` | Forward-auth + IP | **A** (OIDC) | OIDC nativo por variáveis (`OAUTH_*`, `OPENID_PROVIDER_URL`). Melhor piloto. | – |
| bergastream | web/api | `bergastream` | 3 rotas + JWT próprio | **A** (OIDC) | Em desenvolvimento. Até lá: E (uma rota, sem forward-auth nem bypass). | Em andamento |
| transcriptor | transcriptor | `transcriptor` | Forward-auth + IP | **A** (OIDC, código próprio) | Até o OIDC, C na interface. A API v1 (`X-API-Key`) precisa de rota própria fora do forward-auth. | – |
| jellyfin | legendarr-web | `legendarr` | D | **A** (OIDC, código próprio) | Até o OIDC, C. O webhook dos *arr é chamado entre containers, então não é afetado. | – |
| bitwarden | vaultwarden | `bitwarden` | 3 rotas + rotas de WebSocket | **A** (OIDC) se a imagem suportar; senão **E** | As extensões e os apps precisam da API sem forward-auth, então a rota é pública e o SSO fica dentro do app. A senha mestra **continua obrigatória** (ela cifra o cofre e nunca passa pelo Authentik). Confirme se a imagem oficial em uso traz SSO (`SSO_ENABLED`). Deixe `SSO_ONLY` desligado no começo. `/admin` com o token desligado. Revisar as rotas `-ws-*` para a porta 3012, que deve estar obsoleta. | – |
| wazuh | dashboard | `wazuh` | D | **A** (SAML) | O Wazuh documenta SSO com o Authentik por **SAML**, com papéis de admin e de somente leitura. | – |
| litellm | litellm | `llm` | D | **A** (OIDC) na interface | O SSO da interface é gratuito até 5 usuários. A API continua com chaves próprias, na mesma rota. | – |
| n8n | n8n | `n8n` | Forward-auth + IP | **C** no editor; `/webhook*` em **E** | OIDC no n8n é pago (Enterprise). O n8n mantém o próprio login atrás do Authentik (login duplo). Os webhooks externos precisam da rota pública. | – |
| homepage | homepage | `homepage` | D | **C** | Não tem login | – |
| traefik | painel | `traefik` | D + basic auth | **C** | Substitui o basic auth | – |
| jellyfin | sonarr, radarr, prowlarr, bazarr, sabnzbd, qbittorrent | um por serviço | D | **C** | Desligar o login próprio (`External` nos *arr) para não ter login duplo. Apps de celular para os *arr (nzb360, LunaSea) param de funcionar de fora. Corrigir as labels incompletas do radarr. | – |
| bergastream | lidarr | `lidarr` | D | **C** | Idem *arr | – |
| cloudbeaver | cloudbeaver | `db` | 3 rotas | **C**, ou remover | A edição gratuita não tem SSO. Hoje não alcança nenhum banco. | – |
| jellyfin | jellyfin | `jellyflix` | E, sem CrowdSec | **B** (LDAP) | LDAP feito. Falta o `crowdsec-bouncer`. | Em andamento |
| jellyfin | catalogo (Seerr) | `catalogo` | Forward-auth + IP | **E** | O login é pela conta do Jellyfin, que já usa LDAP. Se a versão tiver OIDC, A. | – |
| homeassistant | homeassistant | `ha` | 3 rotas (bypass para o Companion) | **E** | O app Companion fala direto com a API. Proteção: login do HA com MFA. Configurar `trusted_proxies`. OIDC só por integração da comunidade. | – |
| drop | drop | `drop` | E | **E** | Público por decisão. Acrescentar `crowdsec-bouncer`. | – |
| authentik | server | `authentik` | Público; `/if/admin` em D | **E**, com 2FA obrigatório para admins | É a porta de entrada de tudo, então o 2FA e as atualizações são inegociáveis. `/if/admin` pode continuar em D. | – |
| authentik | server | `auth` | Público | **Remover** | Host duplicado, provável sobra da migração de domínio | – |
| *infra* | Proxmox | IP local | Login local | **D** + OIDC | Tem realm OIDC nativo, mas o hipervisor não deve ficar na internet | – |
| *infra* | OpenMediaVault | IP local | Login local | **D** | Interface em PHP: manter sempre atualizado | – |
| wazuh | manager | portas 1514/1515/514/55000 | Publicadas | Revisar | Os agentes precisam da 1514/1515; a 55000 (API) não precisa ficar exposta | – |
| vários | outpost LDAP, ollama, flaresolverr, torrent-indexer, litellm-updater, workers, bancos | – | Vários na `bergatrix-proxy`; flaresolverr e torrent-indexer com rota | **F** | Tirar as rotas e sair da `bergatrix-proxy` (ver redes) | – |

## O que precisa existir no Authentik

1. **2FA obrigatório** para quem acessa apps dos modelos A e C. Isso se faz no fluxo de login, com o estágio de validação configurado para negar quem não tem 2FA cadastrado.
2. **Um grupo por app**, com a aplicação vinculada a ele por *binding*: só quem está no grupo passa.
3. **Um provider por app.**
   - **Modelo C:** provider *Proxy* em modo *Forward auth (single application)*, servido pelo outpost embutido, que é o que o middleware `authentik@file` já usa.
   - **Modelo A:** provider *OAuth2/OpenID* ou *SAML*.
4. **Atualizações em dia:** a imagem do Authentik fica fixada na versão e precisa acompanhar as correções de segurança. Com tudo passando por ele, uma falha no Authentik expõe todos os serviços.

## Redes

| Rede | Destino |
|---|---|
| `bergatrix-proxy` | Só o Traefik e os serviços **com rota** |
| `bergatrix-ldap` (nova) | Outpost LDAP e os apps que usam LDAP |
| `bergatrix-ai` (nova) | Ollama, Open WebUI, LiteLLM e o worker do Legendarr |
| `bergatrix-media` (nova, substitui `media-internal`) | Os *arr, SABnzbd, Prowlarr e o Lidarr do bergastream |
| `<stack>-internal` | Bancos e serviços internos de cada stack (sem mudança) |

## Traefik (`dynamic.yml`)

| Item | Destino |
|---|---|
| `api-access-bypass` | Remover quando nenhuma rota usar mais |
| Rotas `-direct` com `ClientIP` | Remover (é o fim dos IPs fixos) |
| `internal-only` (3 IPs fixos) | Substituído por `lan-only` (a sub-rede), só para a infraestrutura |
| `authentik` (forward-auth) | Manter (modelo C). Testar sem `Authorization` em `authResponseHeaders`, que já atrapalhou o login do Bergastream. |
| `public-auth` | Remover; usar `authentik@file` direto |
| `proxyProtocol` e `forwardedHeaders` (`10.100.0.1`) | Revisar junto com o caminho do tráfego externo |

## Decisões em aberto

1. **Caminho do tráfego externo:** a configuração ainda espera um proxy em `10.100.0.1`, mas a VM nova não tem túnel. Confirmar como o tráfego de fora chega hoje.
2. **Apps de celular dos *arr:** se você usa algum, as rotas dos *arr precisariam de uma exceção por chave de API, o que traz de volta parte do bypass.
3. **CloudBeaver:** remover ou dar uma função para ele.

## Ordem sugerida

1. **Base no Authentik:** 2FA obrigatório no fluxo, grupos e o padrão de provider (*Proxy* e *OIDC*).
2. **Redes e serviços F:** tirar rotas e acessos desnecessários à `bergatrix-proxy`. Nada muda para quem usa.
3. **Open WebUI → OIDC**, o piloto de OIDC.
4. **Homepage e painel do Traefik → C**, o piloto de forward-auth de uma rota só.
5. **Jellyfin:** CrowdSec. **Seerr e Drop:** uma rota só, com CrowdSec.
6. **Os *arr e o Lidarr → C**, com `External`.
7. **Vaultwarden e Home Assistant:** uma rota pública só, e o SSO do Vaultwarden se a imagem suportar.
8. **n8n:** editor em C e webhooks em E.
9. **LiteLLM (OIDC) e Wazuh (SAML).**
10. **`dynamic.yml`:** remover `api-access-bypass`, `public-auth` e os IPs fixos.
11. **Bergastream, Transcriptor e Legendarr → OIDC** no código, seguindo o Bergalink.
