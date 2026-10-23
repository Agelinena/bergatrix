# Plano: novo modelo de acesso (Traefik + Authentik)

Plano para trocar o modelo atual de três rotas (forward-auth do Authentik, acesso direto por IP e bypass em `/api-access-bypass`) por um modelo em que **o Authentik é a porta de entrada de quase tudo**, inclusive de fora de casa, sem depender de VPN. Cada serviço tem uma única rota. A migração é gradual: atualize a coluna "Estado" conforme avançar.

## Decisões tomadas (outubro de 2026)

- **Login único pelo Authentik**, com 2FA, para todos os serviços com interface:
  - **OIDC no app:** Bergalink, Bergastream, Transcriptor, Vaultwarden, Immich e Home Assistant;
  - **forward-auth:** Wazuh, CloudBeaver, os *arr, o painel do Traefik e o Legendarr.
- **Público sem Authentik:** só o Drop.
- **Só pela VPN:** Proxmox, OMV e o Ubuntu (SSH e o host Docker). A VPN é o Tailscale, gerenciado no firewall, fora da VM do Docker.
- **Nada sem Authentik na frente, nem na rede local.** O padrão de rotas e labels está em [05-acesso.md](05-acesso.md).
- **Removidos:** Homepage, Open WebUI, LiteLLM e n8n (sem uso). O Ollama ficou numa stack própria, porque o Legendarr usa.
- **Fim** das rotas `-direct` por IP fixo, da rota `-bypass` e do middleware `api-access-bypass`.

## Os modelos

| Modelo | Quando usar | Rota no Traefik |
|---|---|---|
| **A. SSO nativo (OIDC ou SAML)** | O app sabe falar com o Authentik sozinho | `crowdsec-bouncer` |
| **B. LDAP** | Sem OIDC, mas aceita LDAP e tem cliente de TV ou celular ([guia](guias/autenticacao-ldap.md)) | `crowdsec-bouncer` |
| **C. SSO na frente (forward-auth)** | Sem OIDC: o Authentik pede o login antes de deixar passar | `crowdsec-bouncer` + `authentik@file` |
| **D. Só rede local/VPN** | Só a infraestrutura fora do Docker (Proxmox, OMV, SSH) | Fora do Traefik |
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
| bergastream | web/api | `bergastream` | 3 rotas + JWT próprio | **A** (OIDC) | Em desenvolvimento. Até lá: E (uma rota, sem forward-auth nem bypass). | Em andamento |
| transcriptor | api | `transcriptor` | Forward-auth + IP | **A** (OIDC, código próprio) | Reescrito: login OIDC no app, uma rota com `crowdsec-bouncer`, tokens pessoais no lugar da `X-API-Key`. | No repositório (falta subir) |
| jellyfin | legendarr-web | `legendarr` | D | **C** | Forward-auth (decisão de out/2026, no lugar do OIDC). O webhook dos *arr é chamado entre containers e não passa pelo Traefik. | ✓ |
| bitwarden | vaultwarden | `bitwarden` | 3 rotas + rotas de WebSocket | **A** (OIDC) | As extensões e os apps precisam da API sem forward-auth, então a rota é pública e o SSO fica dentro do app (`SSO_ENABLED`, `SSO_AUTHORITY`, `SSO_CLIENT_ID`, `SSO_CLIENT_SECRET`). A senha mestra **continua obrigatória**: ela cifra o cofre e nunca passa pelo Authentik. Deixe `SSO_ONLY` desligado no começo. `/admin` com o token desligado. Revisar as rotas `-ws-*` para a porta 3012, que deve estar obsoleta. | ✓ |
| wazuh | dashboard | `wazuh` | D | **C** | O dashboard mantém o próprio login atrás do Authentik. (SSO por SAML com papéis é possível no futuro.) | ✓ |
| traefik | painel | `traefik` | D + basic auth | **C** | Substitui o basic auth | ✓ |
| jellyfin | sonarr, radarr, prowlarr, bazarr, sabnzbd, qbittorrent | um por serviço | D | **C** | Desligar o login próprio (`External` nos *arr) para não ter login duplo. Apps de celular para os *arr (nzb360, LunaSea) param de funcionar de fora. Corrigir as labels incompletas do radarr. | ✓ |
| bergastream | lidarr | `lidarr` | D | **C** | Idem *arr | ✓ |
| cloudbeaver | cloudbeaver | `db` | 3 rotas | **C**, ou remover | A edição gratuita não tem SSO. Hoje não alcança nenhum banco. | ✓ |
| jellyfin | jellyfin | `jellyflix` | E, sem CrowdSec | **B** (LDAP) | LDAP feito. `crowdsec-bouncer` com exceção para imagens e streaming (`02-security/crowdsec/whitelists`). | No repositório (falta subir) |
| jellyfin | catalogo (Seerr) | `catalogo` | Forward-auth + IP | **E** | Login pela conta do Jellyfin, que já usa LDAP (a senha conferida é a do Authentik). Login local do Seerr desligado em *Settings → Users*. Observar bans do CrowdSec por pôsteres com 404. | ✓ |
| immich | immich-server | `fotos` | – (stack nova) | **A** (OIDC) | Uma rota, sem forward-auth, porque o app do celular fala direto com a API. Redirect URIs `app.immich:///oauth-callback`, `/auth/login` e `/user-settings`; grupo `immich_users`. Login por senha desligado depois do teste (`immich-admin enable-password-login` em emergência). O client secret fica no banco do Immich, não no `.env`. Precisa do `readTimeout` de 600 s no Traefik. | No repositório (falta subir) |
| homeassistant | homeassistant | `ha` | 3 rotas (bypass para o Companion) | **A** (OIDC) | Sem OIDC nativo: usa a integração da comunidade `hass-oidc-auth` (HACS). A rota fica pública, sem forward-auth, porque o app Companion fala direto com a API. Manter um usuário local com MFA como acesso de emergência. Configurar `trusted_proxies`. | – |
| drop | drop | `drop` | E | **E** | Público por decisão. Uma rota com `crowdsec-bouncer` e rate limit, rede isolada `bergatrix-drop`. | No repositório (falta subir) |
| authentik | server | `authentik` | Público; `/if/admin` em D | **E**, com 2FA obrigatório para admins | É a porta de entrada de tudo, então o 2FA e as atualizações são inegociáveis. `/if/admin` pode continuar em D. | ✓ |
| authentik | server | `auth` | Público | **Remover** | Host duplicado, provável sobra da migração de domínio | – |
| *infra* | Proxmox | IP local | Login local | **D** (VPN) | OIDC nativo é opcional; o acesso de fora é só pela VPN | – |
| *infra* | OpenMediaVault | IP local | Login local | **D** (VPN) | Interface em PHP: manter sempre atualizado | – |
| *infra* | Ubuntu (VM Docker) | IP local | SSH | **D** (VPN) | SSH só pela rede local e pela VPN, com chave | – |
| wazuh | manager | portas 1514/1515/514/55000 | Publicadas | Revisar | Os agentes precisam da 1514/1515; a 55000 (API) não precisa ficar exposta | – |
| vários | outpost LDAP, worker do Authentik, ollama, flaresolverr, torrent-indexer, worker do Legendarr, bancos | – | Vários na `bergatrix-proxy`; flaresolverr e torrent-indexer com rota | **F** | Sem rota e fora da `bergatrix-proxy`, cada um na rede do assunto ([06-redes.md](06-redes.md)) | No repositório (falta subir) |

## O que precisa existir no Authentik

1. **2FA obrigatório** para quem acessa apps dos modelos A e C. Isso se faz no fluxo de login, com o estágio de validação configurado para negar quem não tem 2FA cadastrado.
2. **Um grupo por app**, com a aplicação vinculada a ele por *binding*: só quem está no grupo passa.
3. **Um provider por app.**
   - **Modelo C:** provider *Proxy* em modo *Forward auth (single application)*, servido pelo outpost embutido, que é o que o middleware `authentik@file` já usa.
   - **Modelo A:** provider *OAuth2/OpenID* ou *SAML*.
4. **Atualizações em dia:** a imagem do Authentik fica fixada na versão e precisa acompanhar as correções de segurança. Com tudo passando por ele, uma falha no Authentik expõe todos os serviços.

## Redes

Feito: `bergatrix-proxy` só com quem tem rota, mais `bergatrix-media`, `bergatrix-ldap` e `bergatrix-ai`, todas em `01-network/redes`. Detalhes em [06-redes.md](06-redes.md).

## Traefik (`dynamic.yml`)

| Item | Destino |
|---|---|
| `api-access-bypass` | Só a rota `-bypass` do Home Assistant usa. Sai com o OIDC dele. |
| Rotas `-direct` com `ClientIP` | Só no Home Assistant. Sai com a migração dele. |
| `internal-only` (3 IPs fixos) | ✓ Removido. O painel admin do Authentik usa o `lan-only` (a sub-rede). |
| `authentik` (forward-auth) | Manter (modelo C). Testar sem `Authorization` em `authResponseHeaders`, que já atrapalhou o login do Bergastream. |
| `public-auth` | Só o Home Assistant usa. Remover depois dele. |
| `proxyProtocol` e `forwardedHeaders` (`10.100.0.1`) | Revisar junto com o caminho do tráfego externo |

## Decisões em aberto

1. ~~Qual VPN~~ → Tailscale gerenciado no firewall.
2. **Caminho do tráfego externo:** a configuração ainda espera um proxy em `10.100.0.1`, mas a VM nova não tem túnel. Confirmar como o tráfego de fora chega hoje.
3. **Apps de celular dos *arr:** se você usa algum, as rotas dos *arr precisariam de uma exceção por chave de API, o que traz de volta parte do bypass.
4. **CloudBeaver:** remover ou dar uma função para ele.
5. **Host `auth`:** confirmar se algum app ainda usa `auth.<domínio>` antes de remover a rota.

## O que falta

Feito: base no Authentik, redes, painel do Traefik, *arr, Lidarr, Legendarr, Seerr, Vaultwarden, Wazuh e CloudBeaver.

1. **Jellyfin:** subir com o CrowdSec e acompanhar os bans nos primeiros dias.
2. **Drop:** subir a versão 2 (rede `bergatrix-drop`, CrowdSec e rate limit). Ver o [README](../03-apps/drop/README.md#subir).
3. **Transcriptor:** subir a versão nova (OIDC, Postgres, worker isolado). Ver o [README](../03-apps/transcriptor/README.md#subir).
4. **Home Assistant → OIDC** (`hass-oidc-auth`), com uma rota pública só. Tira a rota `-direct`, a `-bypass` e o `public-auth`.
5. **`dynamic.yml`:** remover `public-auth` e `api-access-bypass` quando os itens 3 e 4 estiverem no ar.
6. **Wazuh:** revisar a porta 55000.
7. **Bergastream:** OIDC no código, seguindo o Bergalink.
8. **Immich:** subir com o OIDC e o timeout novo do Traefik. Ver o [README](../03-apps/immich/README.md#subir). Fotos de verdade só depois do backup do `USERDATA_PATH`.
