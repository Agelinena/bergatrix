# ghostmap — Geocodificador privacy-first via Whoogle + Nominatim, com UI/PWA Flask que gera links geo:/OpenStreetMap

> **Categoria:** app | **Caminho:** `03-apps/ghostmap` | **Status:** active

## 🎯 Finalidade
GhostMap e um app web/PWA minusculo (Flask single-file) cujo objetivo e converter uma busca de endereco ou ponto de interesse em coordenadas geograficas **sem expor a busca diretamente aos servidores do Google**. O usuario digita um endereco numa UI dark estilo Material Design; o backend faz scraping da pagina de resultados do **Whoogle** (proxy anonimo do Google) procurando coordenadas embutidas nos links de mapa e, se nao encontrar, cai para a API publica do **Nominatim** (OpenStreetMap).

O resultado vira um link clicavel que abre o app de mapas nativo no celular (esquema `geo:`) ou o OpenStreetMap no desktop. O historico das ultimas 10 buscas e guardado no `localStorage` do navegador — nao ha banco de dados no servidor. O posicionamento exibido no rodape e "Privacy First • Local Search".

## 🧱 Stack tecnologica
- **Linguagem:** Python 3.9 (imagem base `python:3.9-slim`)
- **Backend:** Flask (servidor de desenvolvimento embutido), `requests`, `BeautifulSoup4` (parser `html.parser`)
- **Frontend:** HTML/CSS/JS vanilla totalmente inline em um unico template — sem framework, sem build step, sem `node_modules`
- **PWA:** `manifest.json` + icone, instalavel
- **Servico de busca:** Whoogle Search (`benbusby/whoogle-search`)
- **Geocodificacao fallback:** Nominatim / OpenStreetMap API
- **Infra:** Docker / Docker Compose, Traefik como reverse proxy

## 📦 Servicos / Containers

| Servico | Imagem / Build | Portas | Volumes | Redes | depends_on | Restart | Healthcheck | Traefik |
|---|---|---|---|---|---|---|---|---|
| **whoogle** | `benbusby/whoogle-search` | nenhuma publicada | nenhum | `ghost-network` | — | `unless-stopped` | nenhum | nao exposto |
| **ghostmap** | build `.` (Dockerfile `python:3.9-slim`) | nenhuma publicada (so via Traefik na 5000) | `${STORAGE_PATH}/ghostmap:/app/data` | `ghost-network`, `bergatrix-proxy` | `whoogle` | `unless-stopped` | nenhum | sim (ver abaixo) |

Detalhes adicionais:
- **whoogle:** `container_name: whoogle`; `security_opt: no-new-privileges`. Flags de ambiente: `WHOOGLE_CONFIG_DISABLE=1` (hardcoded) e `WHOOGLE_CONFIG_COUNTRY` / `WHOOGLE_CONFIG_LANGUAGE` / `WHOOGLE_CONFIG_TOR` / `WHOOGLE_CONFIG_ANON_VIEW` com defaults inline (`BR` / `lang_pt` / `0` / `1`) via `${VAR:-default}`. Acessivel apenas internamente em `http://whoogle:5000` pela `ghost-network`. Sem volume, sem healthcheck, sem GPU/limites.
- **ghostmap:** `container_name: ghostmap`. Dockerfile define `ENV PYTHONUNBUFFERED=1`, `WORKDIR /app`, instala `flask requests beautifulsoup4` via pip inline e roda `CMD ["python", "app.py"]`. O Flask escuta em `0.0.0.0:5000` (servidor de desenvolvimento), porta exposta somente ao Traefik. Sem healthcheck e sem recursos/GPU declarados.

## 🌐 Dominios / Roteamento
- **Hostname:** `ghostmap.${DOMAIN}`
- **Labels Traefik (servico ghostmap):**
  - `traefik.enable=true`
  - `traefik.docker.network=bergatrix-proxy`
  - router `ghostmap-router` com rule `Host(\`ghostmap.${DOMAIN}\`)`
  - `entrypoints=websecure`
  - `tls=true` (sem `certresolver`) — consome o wildcard `*.daberga.com` compartilhado do Traefik; nao emite certificado individual
  - service `ghostmap-service` -> `loadbalancer.server.port=5000`
- **Middlewares:** nenhum declarado neste compose (sem forward-auth/Authentik nos labels). O servico Whoogle e **interno apenas** (sem labels Traefik).

## 📐 Regras de negocio
1. **Pipeline de geocodificacao em 3 tentativas encadeadas (fail-through):**
   1. Whoogle com query `"<endereco> maps"`;
   2. se nao houver lat/lon, Whoogle com a query crua `"<endereco>"`;
   3. se ainda nao houver lat/lon, API publica do Nominatim (`format=json`, `limit=1`).
2. **Extracao de coordenadas do HTML do Whoogle (scraping de `<a href>`)** — ordem de avaliacao **em runtime** dentro do loop principal: (1) parametro `ll=` no href; (2) padrao `@lat,lon` no href. Se o loop principal nao retornar, um segundo loop de fallback varre links que casam `google.com/maps/place/` aplicando o regex `@lat,lon`. *Observacao:* os comentarios `Logic 1/2/3` no codigo estao numa ordem diferente da execucao real (rotulam o `@lat,lon` como "Logic 1" embora o `ll=` seja checado primeiro).
3. **`formatted_address`** e extraido do parametro `q` da query string do link do mapa quando disponivel; senao usa o endereco digitado. No fallback `maps/place` o `formatted_address` nao e extraido (fica `None`).
4. **geo URI do backend:** a resposta de sucesso inclui `geo_uri = "geo:<lat>,<lon>?q=<lat>,<lon>(<endereco>)"`. **Importante:** o frontend **ignora** esse campo e reconstroi o proprio link, perdendo o rotulo entre parenteses (ver Notas de evolucao).
5. **Decisao de link por user-agent (frontend):** mobile (`Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini`) -> `geo:lat,lon?q=lat,lon` (sem `target`, sem rotulo de endereco); desktop -> `https://www.openstreetmap.org/?mlat=<lat>&mlon=<lon>&zoom=17` em nova aba (`target=_blank`).
6. **Historico client-side:** deduplica por endereco exato (remove duplicata e move ao topo via `unshift`), limita a 10 entradas (FIFO via `unshift` + `pop`), persistido em `localStorage`. Ha remocao de item individual e limpar tudo (com `confirm()`).
7. **Diagnostico:** em falha de extracao, salva o HTML `prettify` do Whoogle em `data/debug_failed_search.html` (sobrescrito a cada falha).
8. **Mensagens ao usuario** em pt-BR (ex.: "Local ou endereco nao encontrado. Tente adicionar cidade ou estado.", "Erro de conexao com o servidor.").

Nao ha cron, workers ou agendamentos.

## 🗄️ Modelo de dados
Nao ha banco de dados nem modelo de dados server-side persistente. O unico volume (`${STORAGE_PATH}/ghostmap:/app/data`) serve apenas para gravar o arquivo de debug `data/debug_failed_search.html`. O codigo escreve em `os.path.join(os.getcwd(), 'data', ...)` com `os.makedirs(..., exist_ok=True)`; como o `WORKDIR` e `/app`, o caminho coincide com o mount `/app/data`.

O unico "estado" do usuario e o historico das 10 ultimas buscas (`address`, `lat`, `lon`, `timestamp` em epoch ms), vivendo no `localStorage` sob a chave `ghostMapHistory` em JSON.

## 🔌 Endpoints / API
- `GET /` — renderiza `templates/index.html` (a UI/PWA).
- `POST /search` — recebe JSON `{address}` e retorna:
  - **200** `{success:true, geo_uri, lat, lon, address}`
  - **400** `{success:false, error:"Address is required"}` (campo `address` ausente)
  - **404** `{success:false, error:"Local ou endereco nao encontrado. Tente adicionar cidade ou estado."}` (coordenadas nao encontradas)

## 🔗 Integracoes externas
- **Whoogle Search** (interno a stack, default `http://whoogle:5000`, endpoint `/search`) — proxy de busca Google anonimizado, configurado para BR/`lang_pt`, sem Tor, anon-view ligado, `WHOOGLE_CONFIG_DISABLE=1`. O app envia um `User-Agent` de browser desktop (Chrome 91 / Windows) nas chamadas.
- **Nominatim / OpenStreetMap** (`https://nominatim.openstreetmap.org/search`) — geocodificacao fallback, API publica (`User-Agent: GhostMap/1.0 (internal tool)`, `format=json`, `limit=1`); sujeita a usage policy do OSM.
- **OpenStreetMap** (`openstreetmap.org`) — destino dos links de visualizacao no desktop.
- **Apps de mapas nativos** via esquema `geo:` no mobile.
- **Let's Encrypt** — CA do wildcard `*.daberga.com`; o certificado e emitido uma unica vez pela stack do Traefik (este app apenas o consome via `tls=true`).

## 🧩 Dependencias internas (Bergatrix)
- **Traefik** (stack de reverse proxy do Bergatrix) — roteamento HTTPS via labels, entrypoint `websecure`, serve o wildcard `*.daberga.com` compartilhado via `tls=true` (sem `certresolver` proprio).
- **`bergatrix-proxy`** — rede Docker **externa** compartilhada, usada pelo Traefik para alcancar o container.
- **`ghost-network`** — rede Docker **interna** (nao externa) da propria stack, isola a comunicacao `ghostmap <-> whoogle`.
- **`STORAGE_PATH`** — convencao de armazenamento persistente do homelab (host bind mount para `/app/data`).

## 🔑 Variaveis de ambiente necessarias
*(apenas nomes — nenhum valor)*

- **Infra / roteamento:** `DOMAIN`, `STORAGE_PATH`
- **Configuracao do Whoogle:** `WHOOGLE_CONFIG_COUNTRY`, `WHOOGLE_CONFIG_LANGUAGE`, `WHOOGLE_CONFIG_TOR`, `WHOOGLE_CONFIG_ANON_VIEW` (e `WHOOGLE_CONFIG_DISABLE`, hardcoded `=1` no compose, nao parametrizada)
- **Lida pelo app, mas ausente do `.env.example` e do compose:** `WHOOGLE_URL` (default `http://whoogle:5000`)

## 🗂️ Estrutura de codigo
- `app.py` (~176 linhas) — modulo Flask: rota `GET /` (serve o template) e `POST /search` (geocodificacao). Contem os helpers `perform_search` (scraping do Whoogle) e `search_nominatim` (fallback OSM), o pipeline de 3 tentativas e o dump de HTML de debug.
- `templates/index.html` (~581 linhas) — SPA self-contained com todo o CSS e JS inline: UI dark, spinner, card de resultado, secao de historico e a logica de `localStorage` / geracao de link por user-agent.
- `static/manifest.json` — manifest PWA (nome, cores `#121212`, display standalone, 2 icones).
- `static/icons/logo-original.png` — icone unico referenciado pelo manifest (para 512x512 e 192x192) e como apple-touch-icon.
- `Dockerfile` — `python:3.9-slim`, `PYTHONUNBUFFERED=1`, `WORKDIR /app`, pip install inline, `CMD python app.py`.
- `docker-compose.yml` — define os servicos `whoogle` e `ghostmap`, redes `ghost-network` (interna) e `bergatrix-proxy` (externa), e os labels Traefik.
- `.env.example` — placeholders de configuracao (sem segredos).

## 🛡️ Gestao de segredos
Nao ha segredos proprios nesta stack. Nenhuma API key, token ou credencial e usada — o Whoogle interno nao tem auth e o Nominatim e uma API publica anonima. O `.env.example` contem apenas placeholders (`DOMAIN=example.com`, `STORAGE_PATH`) e flags de configuracao do Whoogle. **Nenhum `.env` real esta versionado** — apenas `.env.example` esta sob controle de versao. **Nenhum segredo exposto/commitado foi encontrado.**

Observacao de seguranca: a aplicacao nao possui autenticacao propria; a protecao de acesso dependeria inteiramente de middleware na camada de proxy (Traefik/Authentik), que **nao esta configurado nos labels deste compose**.

## 🚧 Notas de evolucao / pendencias
- **Sem `requirements.txt`:** dependencias instaladas inline no Dockerfile sem pinagem — builds nao reproduziveis.
- **Service Worker apenas esbocado:** o bloco `if ('serviceWorker' in navigator)` adiciona um listener `load` vazio; caching offline **nao** implementado.
- **Servidor de desenvolvimento em producao:** `app.run(host=0.0.0.0, port=5000)` sem WSGI (gunicorn/uwsgi); `debug` nao setado (default `False`).
- **`geo_uri` e codigo morto na pratica:** o frontend ignora o campo e reconstroi o link, perdendo o rotulo de endereco entre parenteses.
- **Manifest:** dois icones apontam para o mesmo PNG; sem icone `maskable` nem favicon dedicado.
- **Scraping fragil:** a extracao depende do markup dos links do Google via Whoogle; dai a cadeia de fallbacks e o dump de debug.
- **`/search` sem hardening:** sem rate limiting, sem validacao de tamanho de input e sem `timeout` nas chamadas `requests.get` (risco de conexao pendurada).
- **Comentarios `Logic 1/2/3` desalinhados** da ordem real de execucao dos regex.

## ❓ Perguntas em aberto
- O acesso ao app e protegido por Authentik/forward-auth em algum middleware **global** do Traefik? Os labels deste compose nao declaram autenticacao, entao o app ficaria publicamente acessivel em `ghostmap.${DOMAIN}`.
- `WHOOGLE_URL` nao esta documentado no `.env.example` nem no compose — e intencional confiar apenas no default `http://whoogle:5000`?
- Ha limpeza/rotacao de `data/debug_failed_search.html`? Ele e sobrescrito a cada falha (nao cresce), mas pode conter conteudo de buscas que falharam.
- O uso do Nominatim publico respeita a usage policy do OSM (uso pesado exige instancia propria)? Ha previsao de self-host do Nominatim se o volume crescer?

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a stack evoluir._
