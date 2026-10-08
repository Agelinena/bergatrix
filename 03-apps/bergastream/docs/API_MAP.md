# Bergastream — Mapa da API (API_MAP.md)

> Criado no Passo 0; atualizado em 07/10/2026 (Passos 1–13), conferido contra o código.
> Base URL: `https://<servidor>/api` (na web, o próprio domínio; nos apps atrás do Traefik,
> `https://bergastream.daberga.com/api-access-bypass/api` — ver `docs/DEPLOY.md`).
> Local: `http://localhost:8000/api`.

**Autenticação:** todas as rotas exigem `Authorization: Bearer <access_token>`, exceto as
marcadas como públicas. Stream e download aceitam também `?t=<token de stream>`.

---

## 1. Busca

| Endpoint | Parâmetros | Resposta |
|---|---|---|
| `GET /api/search` | `q`, `source` = `spotify` \| `ytmusic` \| `youtube` \| `all` (padrão) | `list[SearchResult]` |
| `GET /api/search/full` | `q`, `source` = `spotify` (padrão) \| `ytmusic` \| `deezer` | `FullSearch` = `tracks`, `artists`, `albums` |
| `GET /api/resolve` | `url` (Spotify, Deezer ou YouTube) | `ResolvedLink` |

- `GET /api/search/playlists?q=&source=` (só a origem pedida; sem `source`, as três) → `list[PlaylistResult]`: `provider` (`spotify`\|`deezer`\|`ytmusic`), `external_id`, `title`, `owner`, `track_count`, `image_url`, `url` (abre por `/api/resolve`), `kind` (`playlist`\|`radio`). "rádio <artista>" traz a rádio do artista (YouTube Music) primeiro; links `RD…` do YouTube Music abrem como rádio.
- **`SearchResult`:** `provider`, `external_id`, `title`, `artist`, `album`, `duration_seconds`, `isrc`, `cover_url`, `artist_id`, `album_id`.
- **`ArtistResult`:** `provider`, `external_id`, `name`, `image_url`. **`AlbumResult`:** `provider`, `external_id`, `title`, `artist`, `year`, `image_url`.
- **`ResolvedLink`:** `source` (`spotify`\|`deezer`\|`youtube`), `kind` (`track`\|`album`\|`playlist`), `title`, `subtitle`, `cover_url`, `description`, `total`, `tracks` (até 10.000), `external_url`.

---

## 2. Tocar uma faixa

| Endpoint | Corpo / resposta |
|---|---|
| `POST /api/play` | corpo `SearchResult` → `{"track_id", "status"}`; registra a faixa e põe o download na fila |
| `GET /api/tracks/{track_id}/status` | `{"track_id", "status", "kind"?}` |

Status: `ready`/`done` → pronta; `downloading`/`queued`/`registered` → baixando; `error`/`failed` → erro; `unknown` → desconhecido (o app desiste após 10 seguidos). O player consulta a cada 1,5 s.

---

## 3. Streaming e download

| Endpoint | Autenticação | Observação |
|---|---|---|
| `GET /api/tracks/{id}/stream` | Bearer ou `?t=` | Range (206) |
| `POST /api/tracks/{id}/stream-token` | Bearer | `{"token", "expires_in": 21600}` — vale só para a faixa, 6 h |
| `GET /api/tracks/{id}/download` | Bearer ou `?t=` | Arquivo completo (download para o aparelho) |

O `<audio>` do navegador não envia `Authorization`: a web pede o token e toca `…/stream?t=<token>`.

---

### `POST /api/lyrics`

Corpo `SearchResult` (como o `/api/play`) → `{"found", "synced": [{"time_ms", "text"}], "plain", "source": "lrclib"}`.
Busca no LRCLIB uma vez por faixa e guarda no servidor (tabela `lyrics`).

---

## 4. Playlists

| Endpoint | Quem | Corpo / resposta |
|---|---|---|
| `GET /api/me/playlists` | logado | `list[PlaylistSummary]` (minhas e compartilhadas comigo) |
| `POST /api/playlists` | logado | `{"name", "description"?}` → `PlaylistSummary` (201) |
| `GET /api/playlists/{id}` | membro | `PlaylistDetail` |
| `PATCH /api/playlists/{id}` | dono/editor | `{"name"?, "description"?}` |
| `DELETE /api/playlists/{id}` | dono | 204 |
| `POST /api/playlists/{id}/tracks` | dono/editor | corpo `SearchResult` |
| `POST /api/playlists/{id}/tracks/bulk` | dono/editor | `{"tracks": [SearchResult…]}` (até 10.000, num envio só para manter a ordem) → 202 |
| `DELETE /api/playlists/{id}/tracks/{track_id}` | dono/editor | |
| `PUT /api/playlists/{id}/order` | dono/editor | `{"track_ids": [...]}` → 204 |
| `PUT /api/playlists/{id}/cover` | dono/editor | multipart `file` (JPEG/PNG/WebP, até 5 MB) |
| `GET /api/playlists/{id}/cover` | **pública** | imagem |
| `PUT /api/playlists/{id}/members/{user_id}` | dono | `{"role": "viewer"\|"editor"}` → 204 |
| `DELETE /api/playlists/{id}/members/{user_id}` | dono | 204 |
| `GET /api/users/directory` | logado | `list[Person]` (para convidar) |
| `GET /api/users` · `GET /api/users/{id}/playlists` | admin · próprio/admin | legados |

**Alterações em lote (edição offline dos apps):** `POST /api/playlists/ops` com
`{"ops": [{"op_id": uuid, "type": "create|rename|add|remove|move|delete|cover", ...}]}` (`create` aceita `description`; `cover` recebe `url` da capa original, de host permitido) → `{"results":
[{"op_id", "status": "applied|conflict|gone|forbidden|invalid|retry", "playlist_id"?, "track_id"?,
"current"?}], "refs": {"tmp:…": "<id>"}}`. Aplicadas na ordem, como intenções sobre o estado atual;
`rename` com `base` e `delete` com `base_updated_at` detectam conflito (`force` aplica mesmo assim);
refs `tmp:` permitem criar e editar uma playlist no mesmo lote; reenviar o mesmo `op_id` devolve o
resultado guardado. Detalhes em `backend/app/playlists/ops.py`.

- **`PlaylistSummary`:** `id`, `name`, `description`, `owner` (`Person`), `role` (`owner`\|`editor`\|`viewer`), `track_count`, `duration_seconds`, `people_count`, `cover_url`, `updated_at`.
- **`PlaylistDetail`:** `PlaylistSummary` + `members` (`user`, `role`) + `tracks`.
- **`PlaylistTrack`:** `track_id`, `provider`, `external_id`, `title`, `artist`, `album`, `duration_seconds`, `isrc`, `cover_url`, `added_by`, `added_at`, `position`, `ready`, `size_bytes`.
- **`Person`:** `id`, `username`, `name`.

---

## 5. Artista

| Endpoint | Resposta |
|---|---|
| `GET /api/artists/{provider}/{id}` | `ArtistPage`: `name`, `image_url`, `followers`/`followers_text`, `top_tracks`, `albums` |
| `GET /api/artists/{provider}/{id}/tracks?offset=&limit=` | `TrackPage`: `items`, `offset`, `total`, `next_offset` (limit ≤ 50, offset ≤ 5000) |

`provider` = `spotify` \| `ytmusic` \| `deezer`. Cache de 10 min. A busca dentro do artista é feita no app sobre as páginas carregadas.

---

## 6. Álbum

| Endpoint | Resposta |
|---|---|
| `GET /api/albums/{provider}/{id}` | `AlbumPage`: `title`, `artist`, `artist_id`, `year`, `image_url`, `tracks` |

---

## 7. Histórico e métricas

| Endpoint | Corpo / resposta |
|---|---|
| `POST /api/history` | `{"plays": [{"client_id": uuid, "played_at", "track": SearchResult}]}` — idempotente por `client_id` (os apps reenviam o que tocou offline) |
| `GET /api/me/stats` | `Stats`: `month`, `seconds_month`, `distinct_tracks_month`, `plays_month`, `top_artists`, `top_tracks`, `top_albums` |

---

## 8. Autenticação

| Endpoint | Corpo | Resposta | Autenticação |
|---|---|---|---|
| `GET /api/auth/config` | — | `{"registration_enabled": bool}` | Pública |
| `POST /api/auth/login` | `{"username", "password"}` | `TokenPair` · 401 senha errada · 429 muitas tentativas (`Retry-After`) | Pública |
| `POST /api/auth/register` | `{"username", "password"}` (≥ 8) | `TokenPair` (201) · 403 se desativado · 409 já existe | Pública, só com `ALLOW_REGISTRATION=true` |
| `POST /api/auth/refresh` | `{"refresh_token"}` | `TokenPair` novo (o refresh antigo deixa de valer) · 401 | Pública |
| `POST /api/auth/logout` | `{"refresh_token"}` | 204 | Pública |
| `GET /api/auth/me` | — | `UserOut` | Bearer |

**`TokenPair`:** `access_token` (JWT, 15 min), `refresh_token` (opaco, 30 dias), `token_type: "bearer"`, `expires_in` (segundos), `user`.
**`UserOut`:** `id`, `username`, `name`, `is_admin`.

Regras:
- Senhas com Argon2. Username não diferencia maiúsculas.
- Refresh com **rotação**: cada uso gera outro; reusar um já trocado revoga a família inteira (todas as sessões daquele login).
- 5 falhas por usuário+IP bloqueiam por 15 min (`LOGIN_MAX_FAILURES`, `LOGIN_BLOCK_MINUTES`).
- Usuários são criados pela linha de comando: `docker compose exec api python -m app.auth.cli create-user <nome> [--admin]` (também `set-password` e `list-users`).
- Todas as outras rotas `/api/*` exigem Bearer; `POST /api/admin/cleanup` (antes `GET`) exige admin.

---

## 9. Imagens

| Endpoint | Autenticação | Observação |
|---|---|---|
| `GET /api/images?url=<https…>` | **pública** | Proxy de capas para a web (CORS). Hosts: `scdn.co`, `spotifycdn.com`, `googleusercontent.com`, `ytimg.com`, `dzcdn.net`. Só https, sem seguir redirecionamentos, até 5 MB, cache em disco, `Cache-Control` de 30 dias. |

---

## 9b. Situação do servidor

| Endpoint | Quem | Resposta |
|---|---|---|
| `GET /api/server/status` | logado | `storage` (`tracks`, `permanent`, `cache`, `bytes`, `bytes_permanent`, `bytes_cache`, `disk_total`, `disk_free`), `queue` (`waiting`, `active`), `deemix` (`available`, `downloading`, `waiting`, `failed`, `completed`, `items[]` com `title`, `artist`, `status`, `progress`) |

`POST /api/history` aceita `playlist_id` em cada reprodução; `GET /api/me/playlists` devolve
`last_played_at` e vem ordenado pela última tocada.

---

## 9c. Sessão compartilhada ("ouvir junto")

Uma pessoa fica em no máximo uma sessão. Qualquer participante convida e mexe na reprodução; só
quem criou muda as configurações, remove pessoas e encerra.

| Endpoint | Quem | Corpo / resposta |
|---|---|---|
| `GET /api/sessions/me` | logado | `{"current": SessionInfo\|null, "invites": [Invite]}` (o app consulta a cada 20 s) |
| `POST /api/sessions` | logado | `{"name"?, "pause_mode": "all"\|"individual"}` → `SessionInfo` (201) |
| `GET /api/sessions/{id}` | participante | `SessionInfo` |
| `PATCH /api/sessions/{id}` | dono | `{"name"?, "pause_mode"?}` → `SessionInfo` |
| `DELETE /api/sessions/{id}` | dono | encerra para todos (204) |
| `POST /api/sessions/{id}/invite` | participante | `{"user_ids": [...]}` → 204 |
| `POST /api/sessions/{id}/join` · `/leave` · `/decline` | convidado / participante | `join` → `SessionInfo`; os outros 204 |
| `DELETE /api/sessions/{id}/members/{user_id}` | dono | remove (204) |
| `POST /api/sessions/{id}/actions` | participante | mesma ação do WebSocket, por HTTP (reserva) → `Playback` |

`Playback`: `{"queue": [{"uid", "track": SearchResult, "added_by"}], "index", "playing",
"position_ms", "anchor_at", "version"}` — a posição agora é `position_ms + (agora − anchor_at)`
(relógio do servidor, ms) quando `playing`.

**WebSocket** `GET /api/sessions/{id}/ws` — a primeira mensagem é `{"type": "auth", "token":
<access token>}` (fora da URL para não ir para logs). Fecha com **4401** (token inválido: o app
renova e reconecta) ou **4403** (não participa).

- Servidor → app: `hello {session}`, `playback {playback, server_now, by}`, `session {session}`
  (pessoas, online, modo de pausa), `pong {t0, server_now}`, `error {message}`, `ended`,
  `removed`, `left`.
- App → servidor: `ping {t0}` (acerto de relógio) e `action` com `action` =
  `play_list {tracks, index}`, `add`/`add_next {track}`, `remove {uid}`, `move {uid, to}`,
  `jump {uid}`, `next`, `previous`, `seek {position_ms}`, `pause`, `resume` (ignorados no modo
  `individual`), `ended {uid}` (só o primeiro aviso de fim da faixa avança).
- O servidor prepara a faixa atual e a próxima uma vez para todos e avança sozinho se ninguém
  avisar o fim (duração + 20 s).

---

## 10. Administração

| Endpoint | Quem |
|---|---|
| `POST /api/admin/cleanup` | admin — limpa arquivos sem referência e cache vencido |

---

## Ferramentas

- Testes do backend: `backend/tests/test_*.py` (rodar dentro do container da API).
- `python -m app.downloads.verify [--fix]`: confere se o arquivo de cada faixa bate com o título (ffprobe) e repara.
- `python -m app.auth.cli`: usuários (`docs/USUARIOS.md`).
