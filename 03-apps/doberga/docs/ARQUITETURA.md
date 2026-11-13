# Doberga: arquitetura

App de utilidades do dia a dia da família: lista de compras, recorrentes, calendário, notas e o que vier depois.
Um app Flutter (Android, Windows, Linux e web) e uma API, em `doberga.${DOMAIN}`.

O app cresce por **módulos**. O núcleo (login, usuários, espaços, sync offline e a tela "Hoje") é escrito uma vez,
e cada módulo novo só declara as suas tabelas e telas.

## Decisões

| Decisão | Por quê |
|---|---|
| **Offline primeiro nos apps** (Android, Windows, Linux) | Sem conexão (mercado, rua), tudo funciona: o app grava no banco local e manda depois. O banco local é a fonte da tela; o servidor é o ponto de encontro entre aparelhos e pessoas. **A web funciona só online:** usa o mesmo código, com o banco local em memória. |
| **Um protocolo de sync para todos os módulos** (fila de operações + `rev`) | Módulo novo não escreve endpoint de CRUD nem lógica de sync: declara a tabela e entra no `push`/`pull`. |
| **IDs gerados no aparelho** (UUIDv7) | Criar offline sem trocar ID depois. O v7 é ordenado no tempo, bom para índice. |
| **Tudo pertence a um espaço** | O espaço pessoal de cada um e os grupos são a mesma coisa (`spaces`). "Minha lista" e "lista da casa" usam o mesmo código e a mesma checagem de acesso. |
| **Qualquer pessoa cria grupos** e convida por link | O admin cuida só de quem pode usar o app (Authentik); grupos são das pessoas. O admin não vê o conteúdo dos grupos. |
| **Calendário próprio**, sem Nextcloud | Funciona offline, mostra junto os recorrentes e usa os mesmos espaços. |
| **Avisos calculados no aparelho** (notificações locais) | Funcionam sem servidor e sem internet. Push pelo servidor (ntfy) fica para depois, para a web e para avisar outra pessoa. |
| **Login como no Berganews** | Servidor como cliente OIDC, código de uso único e PKCE do app. Módulo `auth` copiado. |
| **Sem `egress`** | O servidor não busca nenhum endereço vindo das pessoas (links de compra só são guardados e abertos no aparelho). Se um dia houver prévia de link ou preço, entra o proxy `egress`, como no Berganews. |

## Serviços e redes

```
app (Flutter) ──▶ Traefik ──▶ web (nginx) ──▶ api ──┬─▶ db, redis        (doberga-internal)
                                                     └─▶ authentik-server (bergatrix-proxy)
```

| Serviço | O quê | Redes |
|---|---|---|
| `web` | Flutter web no nginx; repassa `/api/` à API. Única rota no Traefik (`crowdsec-bouncer@file`) | `doberga-internal`, `bergatrix-proxy` |
| `api` | FastAPI: login, usuários, espaços, convites, sync, eventos (SSE) | `doberga-internal`, `bergatrix-proxy` (só para o Authentik, sem labels) |
| `db` | `postgres:16-alpine`, label `bergatrix.backup.dump=postgres` | `doberga-internal` |
| `migrate` | `dbmate`, roda antes da API | `doberga-internal` |
| `redis` | Estado do login OIDC e pub/sub dos avisos de sync | `doberga-internal` |

Dados: só `${APPDATA_PATH}/doberga/postgres` e `redis`. Sem cache, mídia ou userdata (anexos, se vierem, decidem
isso depois).

Authentik: aplicação `doberga`, grupos `doberga_users` (entra) e `doberga_admins` (admin do app), redirect
`https://doberga.${DOMAIN}/api/auth/oidc/callback`, variáveis `DOBERGA_SSO_CLIENT_ID` e `DOBERGA_SSO_CLIENT_SECRET`.

## Núcleo

### Pessoas e espaços

| Tabela | O quê |
|---|---|
| `users`, `refresh_tokens` | Conta ligada ao Authentik pelo `sub`; sessões com rotação (60 dias, como no Berganews) |
| `spaces` | `kind` = `personal` (um por pessoa, criado no primeiro login) ou `group`; nome, cor, ícone |
| `space_members` | `(space_id, user_id, role)`, com `role` = `owner` ou `member`; `joined_at` |
| `space_invites` | Hash do token, espaço, quem criou, validade, usos restantes |
| `user_prefs` | Abas ligadas e a ordem delas, espaço padrão de cada módulo, tema |

- **Grupos e convites exigem conexão** (criar, renomear, convidar, aceitar, sair).
- **Convite:** o dono gera um link `https://doberga.${DOMAIN}/convite/<token>` (o app abre pelo `app_links`).
  Quem abre precisa estar no `doberga_users`. Aceitar exige conexão.
- **Papéis:** `owner` renomeia, convida, remove membros e apaga o grupo; `member` usa. O último dono só sai
  passando o grupo para outra pessoa.
- **Sair ou ser removido:** no próximo sync o espaço some da lista, e o app apaga os dados dele do aparelho.
- **Admin** (página Usuários, do Berganews): desativar conta, encerrar sessões, ver espaços e membros (sem o
  conteúdo).

### Colunas de toda tabela sincronizada

```sql
id          uuid primary key,       -- UUIDv7 gerado no aparelho
space_id    uuid not null references spaces,
rev         bigint not null,        -- nextval('sync_rev'), por trigger a cada insert/update
updated_at  timestamptz not null,
updated_by  uuid not null references users,
deleted_at  timestamptz             -- apagar é marcar (lápide); a limpeza física roda depois de 90 dias
```

O registro de tabelas (`backend/app/sync/registry.py`) diz quais colunas o aparelho pode escrever e a validação de
cada uma (tipo, obrigatório, tamanho, opções, faixa, referência). É a única coisa que um módulo novo precisa fornecer
ao sync no servidor. O contrato das colunas e do trigger está no fim da migração do núcleo.

- **O espaço de uma linha não muda.** Mover algo de espaço é criar a cópia no outro e apagar a original. Se mudasse,
  quem só está no espaço antigo ficaria para sempre com a versão velha.
- **Referência** (`list_id` de um item, por exemplo) só aponta para linha do mesmo espaço.
- **Eventos** (`append_only`): só se criam e apagam (desfazer), nunca se editam.
- **O `rev` cresce na ordem do commit.** O trigger pega um lock global antes de gerar o `rev` e o segura até o commit.
  Sem isso, duas gravações simultâneas podiam ficar visíveis fora de ordem, e um `pull` avançaria o cursor por cima
  de uma linha que ainda ia aparecer. Para uma família, um lock global não pesa.

### Sync

**No aparelho** (`frontend/lib/local/`, `sqlite3` direto, sem geração de código):

- Toda alteração grava **no mesmo commit** a linha local e uma operação na fila `outbox`:
  `op_id` (UUID), tabela, `row_id`, `kind` (`upsert` | `delete`), **só os campos alterados** e o `base_rev`
  (o `rev` que a linha tinha quando foi editada).
- O banco local é genérico: um espelho das linhas (tabela, id, espaço, `rev` e o JSON da linha), a fila, os
  cursores e a lista de espaços. Os módulos leem as linhas e montam os próprios modelos. Com o volume de uma família,
  tudo é carregado na memória ao abrir, e cada gravação vai para o disco na mesma transação.
- A tela lê sempre o banco local (avisos de mudança por tabela). A rede nunca bloqueia a tela.
- Uma exclusão confirmada pelo servidor sai do banco local na hora (a linha talvez nem tenha chegado ao servidor,
  então a lápide nunca viria).

**Envio:** `POST /api/sync/push` com as operações em ordem, em lotes de até 200.

1. `op_id` já aplicado (tabela `applied_ops`) → responde `ok` de novo. Reenviar é seguro.
2. Confere o acesso ao espaço (e aos dois, se a linha mudou de espaço) e valida os campos.
3. `upsert`: cria a linha se não existe; senão, atualiza **só os campos enviados**. Duas pessoas que mudam
   campos diferentes do mesmo item ficam ambas certas.
4. Linha apagada no servidor → a edição é recusada (`deleted`).
5. Cada operação volta `ok` ou `rejected` com o motivo. A recusada sai da fila, a linha é refeita pelo `pull`, e
   o app mostra um aviso ("Não deu para salvar 'Arroz': o item foi apagado por Fulano").

**Conflito no mesmo campo:** vence a última operação a chegar ao servidor. Os dados são desenhados para quase
nunca precisar de mais que isso:

| Caso | Como fica |
|---|---|
| Marcar recorrente como feito, fechar compra | São **eventos** (linhas novas, só inseridas). Dois aparelhos offline geram dois eventos, sem conflito. |
| Texto de nota editado em dois aparelhos | `base_rev` diferente do `rev` atual no campo `body` → o servidor guarda a versão que chegou como **cópia de conflito** ao lado, em vez de sobrescrever. |
| Quantidade, preço, título, datas | Última escrita vence (raro e fácil de ver). |

**Recebimento:** `POST /api/sync/pull` com o cursor de cada espaço (`{space_id: rev}`); espaço novo começa do zero.

- Volta as linhas com `rev` maior que o cursor, até 500 por vez, mais `has_more`, e a lista atual de espaços
  e membros. Espaço que sumiu da lista → apagado do aparelho.
- Ao gravar uma linha que chegou, o app reaplica por cima as operações que ainda estão na fila para ela.
  Assim uma edição local não "volta" ao valor antigo antes de ser enviada.

**Quando sincroniza:** ao abrir o app; quando a conexão volta (`connectivity_plus`); 2 s depois de uma
alteração local; quando chega um evento; e a cada 5 min com o app aberto. Sempre `push` antes de `pull`.

**Tempo real:** `GET /api/sync/events` (SSE). A cada `push`, a API publica no Redis, no canal **de cada membro**
dos espaços afetados (`doberga:user:<id>`), e o app faz `pull`. Assinar o canal da pessoa, e não o do espaço,
evita trocar a assinatura quando ela entra ou sai de um grupo. O aviso leva o `device_id` de quem mandou, e esse
aparelho o ignora. A conexão dura o tempo do access token (15 min) e o app reconecta. Na web, em vez de SSE, o app
consulta a cada 30 s. É o que faz duas pessoas no mercado verem o que a outra pegou.

**Conta no aparelho:** o banco local é por pessoa (`doberga_<user_id>.db`), então um aparelho compartilhado não
mistura dados. Sessão vencida offline não trava nada: o app continua, e a fila espera o próximo login **da mesma
pessoa**. "Sair" mantém o banco; "Sair e apagar os dados deste aparelho" apaga.

**Sinal ruim:** o refresh token é trocado a cada renovação (rotação), e um token trocado que reaparece derruba a
sessão (sinal de roubo). Com sinal ruim, a resposta da troca se perde e o app repete com o token antigo; por isso
ele ainda vale por 2 minutos depois da troca (`refresh_grace_seconds`).

**Versões:** o app manda `X-Doberga-Sync: <versão do protocolo>`. Uma API que não aceita mais aquela versão
responde 426, e o app pede a atualização (como o Bergastream). O banco local migra pelo `PRAGMA user_version`; o do
servidor, pelo `dbmate`.

**Limpeza** (a cada 6 h, na API): lápides e operações aplicadas com mais de 90 dias, convites vencidos ou esgotados,
sessões vencidas. O maior `rev` de lápide apagada fica em `sync_meta.purged_rev`; um aparelho com cursor abaixo
disso pode ter perdido uma exclusão, e o `pull` manda o espaço em `reset` para ele refazer do zero (mantendo a fila).

### Hoje e Semana

Telas do núcleo. Cada módulo fornece, a partir do banco local, os itens de um intervalo de datas:

| Módulo | Entra no "Hoje" / "Semana" |
|---|---|
| Recorrentes | Atrasados, os de hoje e os dos próximos 7 dias |
| Calendário | Eventos do dia e da semana |
| Compras | Listas com itens pendentes (resumo, com atalho) |

Como os dados são locais, as telas funcionam offline.

### Notificações

`flutter_local_notifications` (Android, Windows, Linux). Depois de cada sync e de cada alteração, o app
reagenda os avisos dos próximos 14 dias a partir do banco local: recorrentes (às 9 h do dia, configurável) e
lembretes de eventos. A web não tem aviso nesta etapa. O push pelo servidor (ntfy, stack compartilhada com o
Berganews) fica para a fase 5.

## Módulos

### Lista de compras

| Tabela | O quê |
|---|---|
| `shopping_lists` | Nome, ícone, ordem |
| `stores` | Onde comprar, por espaço: "Mercado", "Amazon", "Farmácia"… |
| `shopping_items` | Lista, nome, quantidade (`numeric`), unidade (`un`, `kg`, `g`, `l`, `ml`, `pct`), loja, link, nota, valor (centavos, total da linha), estado (`pending`, `in_cart`, `bought`), `purchase_id`, quem adicionou, posição |
| `purchases` | Evento "fechar compra": lista, loja, data, total, quem fechou |

- **Adicionar rápido:** um campo que entende `2kg arroz`, `3 leite`, `arroz 2kg`. O autocompletar vem dos nomes
  já usados no espaço (consulta local, funciona offline), trazendo a última loja e unidade.
- **Comprando:** tocar no item → "no carrinho" e, se quiser, o valor. Para itens em kg, o app mostra também o
  R$/kg. O rodapé soma o carrinho.
- **Fechar compra:** cria um `purchase` com o total, e os itens do carrinho passam a `bought`. Fica o histórico de
  gastos por loja e por mês. "Comprar de novo" volta um item comprado para `pending`.
- **Filtros** (locais): loja, estado, quem adicionou, com link, texto.
- **Links:** guardados e abertos no aparelho (`url_launcher`); o servidor não os acessa.

### Recorrentes

| Tabela | O quê |
|---|---|
| `recurring_lists` | "Casa", "Carro", "Saúde"… |
| `recurring_tasks` | Lista, título, nota, `mode`, `every_n`, `every_unit` (`day`, `week`, `month`, `year`), `anchor_date`, `next_due` (`date`), `notify_days_before`, `paused` |
| `task_completions` | Evento: tarefa, data em que foi feito, quem fez, nota, `skipped` |

| `mode` | Próxima data | Exemplo |
|---|---|---|
| `once` | Nenhuma: feito, sai da lista | Renovar a CNH |
| `after_done` | Data em que foi feito + intervalo | Limpar o ar-condicionado a cada 3 meses |
| `fixed` | Próxima data da série a partir de `anchor_date` | IPVA todo janeiro, dia 10 |

- **Feito:** cria o evento e recalcula `next_due`. Também dá para **adiar** (muda só a `next_due` desta vez) e
  **pular** (evento com `skipped`, a série segue).
- **Datas** são `date`, no fuso da pessoa, nunca `timestamp`: "hoje" não muda por causa de fuso.
- O cálculo da próxima data existe no Dart (offline) e no Python (validação). Um arquivo de casos
  (`shared/recurrence_cases.json`) é testado pelos dois, para os dois nunca divergirem (fim de mês, 29/02).

### Calendário

| Tabela | O quê |
|---|---|
| `calendars` | Por espaço: nome e cor ("Pessoal", "Casa", "Aniversários") |
| `events` | Calendário, título, local, nota, `all_day`, `starts_at`/`ends_at` (ou `start_date`/`end_date` se dia inteiro), fuso, `rrule` (RFC 5545), lembretes (minutos antes) |
| `event_overrides` | Exceções da série: `original_start`, `cancelled` ou campos alterados ("só este") |

- Repetição por `rrule` (pacote `rrule` no Dart, `dateutil` no Python). "Este e os seguintes" corta a série
  (`UNTIL`) e cria uma nova.
- As ocorrências são expandidas no aparelho, só para o intervalo da tela.
- Os recorrentes aparecem no calendário (sem serem eventos).
- Depois: feed `.ics` só de leitura por pessoa (assinar no celular ou em outro calendário), feriados do Brasil.

### Notas

| Tabela | O quê |
|---|---|
| `notes` | Título, `body` (Markdown), fixada, cor, arquivada |

Checklists dentro do Markdown (`- [ ]`). Conflito de texto vira cópia de conflito (ver Sync).

## API

| Rota | Para quê |
|---|---|
| `GET /api/auth/oidc/start`, `/callback`, `POST /exchange`, `/refresh`, `/logout`, `GET /me` | Login (do Berganews) |
| `GET/PATCH /api/admin/users`, `POST …/{id}/logout` | Página Usuários |
| `GET/POST /api/spaces`, `PATCH/DELETE /api/spaces/{id}` | Listar, criar, renomear e apagar grupo |
| `GET/POST /api/spaces/{id}/invites`, `DELETE …/invites/{id}` | Convites do grupo (o link só aparece ao criar) |
| `GET /api/invites/{token}`, `POST …/accept` | Ver o convite e entrar |
| `DELETE /api/spaces/{id}/members/{user_id}`, `PATCH …` | Remover membro, mudar papel, sair |
| `POST /api/sync/push`, `POST /api/sync/pull`, `GET /api/sync/events` | Sync de todos os módulos |
| `GET/PUT /api/prefs` | Preferências |
| `GET /api/app/version` | Versão mínima e a mais recente do app (atualização) |

Os módulos **não** têm rotas próprias de CRUD: tudo passa pelo sync. Rota de módulo só para o que precisa do
servidor (ex.: relatório de gastos de um ano inteiro).

## Organização do código

```
03-apps/doberga/
├── docker-compose.yml, .env.example, README.md
├── docs/ARQUITETURA.md
├── backend/
│   ├── app/
│   │   ├── auth/ users/ prefs/          do Berganews (com a tolerância na renovação)
│   │   ├── spaces/                      espaços, membros, convites
│   │   ├── sync/                        registry (tabelas), engine (push, pull, limpeza), events (SSE), routes
│   │   ├── modules.py                   importa os módulos (registra as tabelas no sync)
│   │   └── core/
│   ├── db/migrations/                   núcleo + uma migração por módulo
│   └── tests/integration_pgserver.py    Postgres de verdade, pelas rotas HTTP
└── frontend/lib/
    ├── auth/        login (do Berganews)
    ├── core/        http, armazenamento seguro, tema, widgets
    ├── data/        modelos e API REST (espaços, convites, preferências, admin)
    ├── local/       banco local: memória (regras) + SQLite (disco); web só memória
    ├── sync/        motor (Dart puro, testado com servidor falso), controlador, SSE, indicador
    ├── spaces/  today/  settings/  admin/
    ├── shell.dart   abas: barra inferior no celular, trilho lateral no computador e na web
    └── (fase 1+) shopping/  recurring/  calendar/  notes/
```

Para um módulo novo: migração com o contrato do núcleo, `register(Table(...))` no backend e a linha em
`modules.py`; no app, a pasta do módulo lendo o banco local (`storeProvider`) e gravando pelo `writerProvider`, a aba
em `TabId`/`shell.dart` e, se tiver data, uma fonte em `agendaSourcesProvider` (Hoje e Semana).

Flutter: Riverpod, dio, `sqlite3`, `flutter_secure_storage`, `app_links`, `connectivity_plus`, `share_plus`,
`url_launcher`, `uuid`. Sem `build_runner`. As próximas fases acrescentam `flutter_local_notifications` e `rrule`.

Releases como no Bergastream: tags `doberga-vX.Y.Z`, APK assinado e builds de Windows e Linux pelo Actions,
atualização pelo próprio app.

## Fases

0. **Núcleo:** stack, login, página Usuários, espaços e convites, motor de sync (com testes de ponta a ponta:
   dois aparelhos, offline, conflito, sair do grupo), shell e "Hoje" vazio, releases.
1. **Lista de compras.**
2. **Recorrentes**, "Hoje" e "Semana", notificações locais.
3. **Calendário.**
4. **Notas.**
5. **Depois:** push (ntfy), feed `.ics`, feriados, relatórios de gastos, anexos, módulos novos.
