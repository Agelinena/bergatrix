# Bergastream: Guia de Implementação do App Flutter

Documento para o **DeepSeek** implementar o app Flutter (Android primeiro, web como base; Windows/Linux depois). Siga os passos **na ordem**, **implementando e testando cada um** antes de começar o próximo.

---

## 0. Regras de trabalho (LEIA ANTES DE QUALQUER CÓDIGO)

1. **Um passo por vez.** Ao terminar um passo, rode todos os testes, valide os critérios de aceite e **pare**. Só avance quando tudo passar e o usuário confirmar.
2. **Cada passo termina com este relatório**, sempre no mesmo formato:
   - O que foi feito (lista curta).
   - Comandos rodados e resultado: `flutter analyze` (0 erros e 0 warnings), `flutter test` (todos passando).
   - Como o usuário pode testar manualmente (passo a passo, com o que deve aparecer na tela).
   - Pendências, dúvidas e desvios do documento (se houver).
3. **Não invente endpoints, campos ou comportamentos do backend.** O backend já existe. O Passo 0 mapeia o que existe; o que faltar vai para uma lista de pendências do backend, e o app usa uma interface (repositório) com implementação fake até lá.
4. **O design é exatamente o da prévia** (Seção 5 e 6). Cores, tamanhos, textos e comportamentos desta documentação são a fonte da verdade. Não "melhore", não troque fontes, cores nem espaçamentos. Se algo parecer errado, pergunte.
5. **Não adicione funcionalidades fora do passo atual.** Itens de "Fora do escopo" (Seção 13) não entram.
6. **Todo texto de interface em português do Brasil**, exatamente como listado na Seção 6.
7. **Código simples e legível.** Nomes claros, sem abstração "para o futuro". Cada feature isolada na sua pasta (Seção 4).
8. **Git:** um commit por passo (`passo-03: autenticação e modos de acesso`).
9. **Se algo estiver ambíguo, pergunte antes de implementar.**
10. **Arquivos de referência do design** (colocar em `docs/design/`): `bergastream_preview.html` (protótipo clicável, abrir no navegador). O protótipo é a referência visual e de comportamento. Ele tem dados fictícios e usa os mesmos ícones Material do Flutter (mesmos nomes). **Não estão no protótipo** e seguem só o texto desta documentação, com o mesmo visual: telas de artista e álbum (6.7), tela de login (2.2), `OfflineBanner` e avisos de sessão (2.3/2.4), botão de download da playlist (8.4), tela "Pessoas" e menu da playlist (6.4), "Baixando…" no mini player (7.3), cartões de opções de download em Ajustes (6.5) e tela Gerenciar downloads (8.5).
11. **Rodar o Flutter:** não há Flutter instalado na máquina de desenvolvimento; use a imagem `ghcr.io/cirruslabs/flutter:stable` montando `frontend/` (os golden tests devem ser gerados e conferidos sempre nessa imagem, para a renderização ser igual).

---

## 1. Visão geral e decisões fixas

Bergastream é um app de streaming musical self-hosted (estilo Spotify). O **backend** (FastAPI + PostgreSQL, download via Deemix/yt-dlp, streaming com HTTP Range) já existe. Este documento cobre **apenas o app Flutter**.

**Decisões fixas**
- Um único código Flutter para Android, Web, Windows e Linux.
- **Foco agora: Android completo e Web como base.** Windows/Linux entram depois, reaproveitando o mesmo código (Passo 13).
- **Web tem layout de navegador próprio** (estilo Spotify Web, Seção 6.8) a partir de 900 px de largura; abaixo disso usa o layout de celular. Android usa sempre o layout de celular.
- **Duas visualizações no build web, para desenvolver sem compilar o APK:** `/` é a versão web (regras e layout da web); `/?modo=android` simula o Android (regras do app da Seção 2.1, layout de celular numa coluna de 430 px). A sessão da simulação é salva separada da sessão da web.
- Gerência de estado: **Riverpod**. Navegação: **go_router**.
- Tema segue o sistema (`ThemeMode.system`): escuro quando o sistema está escuro, claro quando está claro (Seção 5). A paleta escura é a referência principal do design.
- **Modo offline é cidadão de primeira classe** (Seção 8): músicas, playlists, metadados e imagens baixados continuam acessíveis sem servidor.

---

## 2. Plataformas e regras de acesso (AUTENTICAÇÃO)

### 2.1 Matriz de acesso

| Recurso | Web | Android / Windows / Linux **sem login** | Android / Windows / Linux **com login** |
|---|---|---|---|
| Abrir o app e ver a interface | Só após login | Sim | Sim |
| Tela de login ao abrir | **Obrigatória, sempre** | Aparece na 1ª abertura, com botão "Continuar sem entrar" | Pula direto para o app |
| Biblioteca local (músicas baixadas) | Não existe | Sim | Sim |
| Playlists locais (criadas no aparelho) | Não existe | Sim (marcadas "Só neste aparelho") | Sim, além das playlists do servidor |
| Tocar músicas baixadas | n/a | Sim | Sim |
| Busca **local** (nas baixadas e playlists locais) | n/a | Sim | Sim |
| Busca **no servidor** (Spotify / YT Music / links) | Sim, logado | **Não** | Sim |
| Tocar por streaming | Sim, logado | **Não** | Sim |
| Baixar músicas/playlists para o aparelho | Não existe na web | **Não** (precisa do servidor) | Sim |
| Playlists do servidor, colaboração, compartilhamento | Sim, logado | Não | Sim |
| Tela inicial com métricas | Sim, logado | Mostra só dados locais (ou vazio com convite para entrar) | Sim |
| Configurações | Sim | Sim | Sim |

### 2.2 Tela de login (todas as plataformas)

Campos e botões, com o mesmo visual do restante do app:
- Título "Bergastream" (h1) e subtítulo "Entre no seu servidor".
- Campo **Endereço do servidor** (ex.: `https://musica.meuservidor.com`). Na **web** o campo não aparece (usa o mesmo domínio ou um valor definido no build).
- Campo **Usuário** e campo **Senha** (com botão de mostrar/ocultar).
- Botão principal laranja **Entrar**.
- Link **Criar conta**, exibido só se o servidor permitir cadastro (consultar o backend).
- **Somente em Android/Windows/Linux:** botão secundário (chip) **Continuar sem entrar**.
- Erros em texto claro, abaixo do campo: "Servidor não encontrado. Confira o endereço.", "Usuário ou senha incorretos.", "Não foi possível conectar. Verifique sua internet."

### 2.3 Estados de sessão (máquina de estados)

`semServidorConfigurado → deslogado → logando → logado`, e `logado → sessaoExpirada → deslogado`.

Regras:
- **Web:** se não estiver `logado`, só a tela de login é acessível. Nenhuma rota do app abre sem sessão.
- **Mobile/desktop, 1ª abertura:** mostra o login. "Continuar sem entrar" grava a preferência e abre o app em **modo local**.
- **Token** guardado em armazenamento seguro (`flutter_secure_storage`). Renovação automática do token quando expirar (interceptor do `dio`, Passo 4; a lógica de renovação e o estado `sessaoExpirada` já existem no controlador da sessão desde o Passo 3). Se a renovação falhar, estado `sessaoExpirada`: o app **não desloga à força**, continua em modo local e mostra o aviso "Sessão expirada. Entre para buscar no servidor." com botão **Entrar**.
- **Servidor indisponível** (sem rede ou servidor fora do ar) com usuário logado: o app entra em **modo offline**, mostra o aviso discreto "Servidor indisponível. Mostrando suas músicas baixadas." e tudo o que é local continua funcionando. Ao voltar a conexão, o aviso some sozinho.
- **Sair** (em Configurações): apaga o token. As músicas baixadas **permanecem** no aparelho (pergunta: "Manter as músicas baixadas neste aparelho?" com Manter / Apagar tudo).

### 2.4 Comportamento das telas quando não há servidor/login

- **Aba Buscar:** o campo funciona como **busca local** (nas músicas baixadas e playlists locais). Abaixo do campo aparece um card: "Entre para buscar músicas no servidor" com botão **Entrar**. Os chips Spotify / YT Music ficam ocultos.
- **Aba Biblioteca:** mostra playlists locais e as playlists do servidor já baixadas ou em cache. Playlists do servidor não baixadas aparecem esmaecidas com "Indisponível offline".
- **Faixa não baixada:** ao tocar sem servidor, mostrar o aviso rápido (toast): "Esta música não está baixada."
- Botões que dependem do servidor (compartilhar, adicionar do servidor, colaboradores) ficam desabilitados com a mesma explicação em toast.

---

## 3. Stack

Usar sempre a **última versão estável** de cada pacote (restrição `^x.y.z` no `pubspec.yaml`, nunca `any`; travar em `pubspec.lock`). Cada pacote entra no `pubspec.yaml` **no passo que o usa**.

| Necessidade | Pacote |
|---|---|
| Estado | `flutter_riverpod` |
| Navegação | `go_router` |
| HTTP | `dio` (com interceptors de token e erros) |
| Áudio | `just_audio` + `audio_service` (Android: serviço em primeiro plano e notificação com controles) |
| Áudio desktop (Passo 13) | `just_audio_media_kit` |
| Banco local | `drift` + `sqlite3_flutter_libs` (não existe na web) |
| Armazenamento seguro | `flutter_secure_storage` |
| Pastas do sistema | `path_provider` |
| Downloads em segundo plano | `background_downloader` |
| Rede | `connectivity_plus` |
| Imagens de rede com cache | `cached_network_image` |
| Seleção de imagem | `image_picker` / `file_picker` |
| Compartilhar | `share_plus` |
| Gesto de arrastar na lista | `flutter_slidable` |
| JSON | `json_serializable` + `json_annotation` |
| Testes | `flutter_test`, `mocktail`, `integration_test` |

**Fonte:** Bricolage Grotesque (pesos 400, 600, 800), **incluída nos assets do app** (não usar `google_fonts` em tempo de execução, porque o app precisa funcionar offline).

**Ícones:** Material Icons do Flutter (`uses-material-design: true`). A fonte Bricolage **não tem** o caractere ♫; onde o design mostra uma nota musical, usar o ícone `music_note`.

**Plataforma Android:** `minSdk 24`; permissões `INTERNET`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, `WAKE_LOCK`, `POST_NOTIFICATIONS`; `usesCleartextTraffic` apenas em build de debug.

---

## 4. Estrutura de pastas

```
lib/
  main.dart
  app/                 # MaterialApp, router, tema, bootstrap
  core/
    theme/             # tokens de cor, tipografia, medidas
    widgets/           # componentes compartilhados (Seção 5.4)
    network/           # dio, interceptors, erros
    storage/           # secure storage, preferências
    platform/          # helpers kIsWeb / desktop / mobile
    utils/             # formatação de duração, etc.
  features/
    auth/              # login, sessão, modos de acesso
    home/
    search/
    artist/
    album/
    library/           # lista de playlists e detalhe da playlist
    player/            # motor, fila, mini player, player grande
    downloads/         # gerenciador de downloads locais
    settings/
  data/
    api/               # clientes HTTP por área
    models/            # modelos (Track, Playlist, Artist, Album...)
    local/             # drift (banco local)
    repositories/      # interfaces + implementação remota/local/fake
assets/fonts/
docs/design/bergastream_preview.html
test/
integration_test/
```

Regra: cada `feature` só conversa com outras por **repositórios e providers públicos**, nunca importando arquivos internos de outra feature.

---

## 5. Design system (EXATO)

### 5.1 Cores

| Token | Escuro (padrão) | Claro (segue o sistema) |
|---|---|---|
| `bg` (fundo) | `#0B0B0A` | `#F5F4EF` |
| `card` (cartões, campos, mini player, folhas) | `#191917` | `#E8E6DC` |
| `tx` (texto) | `#F2F1EC` | `#14130F` |
| `mu` (texto secundário) | `#8E8D84` | `#6A685C` |
| `ac` (laranja: ações) | `#FF7A1A` | `#D95F00` |
| `gr` (verde: estado/ativo) | `#3FCF6E` | `#1F9A4A` |
| `on` (texto sobre laranja/verde) | `#1A0B00` | `#FFFFFF` |
| scrim (fundo das folhas) | `#000000` a 60% | `#000000` a 60% |

**Regra de uso das cores (importante):**
- **Laranja = o que você toca/aciona:** botão play do mini player e da playlist, botão "Entrar", "Nova playlist", "Adicionar músicas à playlist", chip ativo (Spotify/YT Music, Aleatório ligado).
- **Verde = o que está ativo/acontecendo:** música tocando (título em verde na lista), barra de progresso, números das métricas, "Conectado", avisos rápidos (toast), ícone de música baixada, progresso de download.
- Preto/grafite para toda a estrutura.

### 5.2 Tipografia (Bricolage Grotesque)

| Uso | Tamanho | Peso |
|---|---|---|
| `h1` (título de tela) | 28 | 800 (margem inferior 14) |
| `h2` (título de seção) | 17 | 600 (margem superior 20, inferior 10) |
| Corpo | 15 | 400 |
| Título de faixa (linhas) | 15 | 600 (1 linha, reticências) |
| Texto secundário (`mu`) | 13 | 400 |
| Chips | 13 | 400 (ativo: 600) |
| Botões | 15 | 600 |
| Rótulo da barra de navegação | 12 | 400 |
| Número grande das métricas | 26 | 800 |

Sem texto em caixa-alta. Sentence case em tudo.

### 5.3 Medidas e formas

- Padding das telas: topo 18, laterais 16, **inferior 170** (espaço para mini player e barra de navegação).
- Cover (capa) padrão: raio **8**. Capa da playlist (detalhe): ocupa a largura, proporção quadrada limitada a altura 200, raio 8. Capa do player grande: quadrada, largura total, raio **18**.
- Capa sem imagem: **gradiente linear 135°** de `hsl(H, 65%, 52%)` para `hsl(H+25, 60%, 30%)`, com a **inicial** do título em branco, peso 800, com leve sombra de texto. **H** (matiz) é derivado do id da faixa, limitado ao intervalo **18–150** (laranja → âmbar → verde), com um hash estável entre plataformas (FNV-1a; o `hashCode` de `String` muda entre web e nativo). Tamanho da inicial: ~40% do tamanho da capa (70 no player grande). Título vazio: ícone `music_note`.
- Capa de playlist sem foto (lista e detalhe): gradiente 135° de `hsl(24, 85%, 50%)` para `hsl(140, 60%, 28%)` com o ícone `music_note` em branco.
- Cartões: raio **14**, padding **14**, fundo `card`, margem superior 10.
- Campos de texto: fundo `card`, raio **12**, padding **12×14**, sem borda, texto `tx`, dica em `mu`.
- Chips: raio total (pílula), padding **7×14**, fundo `card`; ativo: fundo `ac`, texto `on`, peso 600.
- Botão principal: pílula, padding **11×18**, fundo `ac`, texto `on`, peso 600.
- Botão circular de play: **38×38** no mini player, 38 na playlist, **60×60** no player grande, fundo `ac`, ícone `on`.
- Linhas de faixa: capa **46×46**, espaçamento 12, padding vertical 7.
- Carrossel horizontal: itens de **96** de largura (capa 96×96), espaço 12; artistas com capa **circular**; legenda 13, centralizada, margem superior 6.
- Barra de progresso do mini player: altura **3**, trilho cinza a ~27% de opacidade, preenchimento `gr`, cantos arredondados. No player grande: altura **5**.

### 5.4 Componentes compartilhados (`core/widgets`)

`Cover`, `TrackRow`, `SectionTitle`, `HorizontalShelf`, `ArtistCircle`, `AlbumTile`, `StatCard`, `AppChip`, `PrimaryButton`, `AppTextField`, `AppToast`, `TrackActionsSheet`, `ProgressBarThin`, `OfflineBanner`, `DownloadStateIcon`.

- **`TrackRow`:** capa 46 + coluna (título 600 em 1 linha; abaixo `artista` e, quando for o caso, ` · por Fulano` em `mu` 13) + botão **⋮** (ícone `more_vert`, cor `mu`). Faixa **tocando agora**: título em `gr`. Faixa baixada no aparelho: ícone pequeno `download_done` em `gr` antes do botão ⋮. Toque na linha = tocar. Toque no ⋮ = abre `TrackActionsSheet`. **Arrastar para o lado** (esquerda ou direita) = adicionar à fila (ver 7.2), com o aviso "Na fila: toca depois da atual".
- **`TrackActionsSheet`** (folha inferior): scrim escuro; painel `card`, cantos superiores raio **22**, padding **16/18/26**. Topo: capa 46 + título e artista. Itens, em linhas de padding vertical 13, alinhados à esquerda, nesta ordem: **Compartilhar**, **Adicionar à playlist**, **Adicionar à fila**, **Ir para o álbum**, **Ir para o artista**. Itens que exigem servidor ficam desabilitados no modo local: texto em `mu`; ao tocar, a folha fecha e mostra um toast com a explicação.
- **`AppToast`:** pílula verde (`gr`, texto `on`, 13/600) centralizada no topo (14 abaixo da borda segura), aparece por **1,5 s** com fade.
- **`OfflineBanner`:** faixa fina logo acima do conteúdo, fundo `card`, padding 8×16, texto `mu` 13, botão de texto `gr` (13/600) quando houver ação ("Entrar").
- **`DownloadStateIcon`** (tamanho 18): `naoBaixada` = nada; `naFila` = `schedule` em `mu`; `baixando` = anel de progresso `gr`; `baixada` = `download_done` em `gr`; `falhou` = `error_outline` em `mu`.

---

## 6. Telas (especificação detalhada)

### 6.1 Estrutura geral (shell)

- Barra de navegação inferior fixa com **4 abas**: **Início** (`home`), **Buscar** (`search`), **Biblioteca** (`library_music`), **Ajustes** (`settings`). Ícone 20, rótulo 12. Aba ativa: ícone e rótulo em `ac`; inativas em `mu`. Borda superior de 1 px na cor `card`. Fundo `bg`. Respeitar a área segura inferior.
- **Mini player** flutuante **acima** da barra de navegação: margem lateral **10**, a **68** de distância da base, raio **14**, fundo `card`, padding **8×10**, sombra suave (deslocamento 6, desfoque 22, preto a 40%). Só aparece quando há faixa carregada.
- Player grande cobre a tela inteira (sobe com animação de 280 ms).
- No **app** (e na simulação `?modo=android`) em telas largas, o layout de celular aparece **centralizado em uma coluna de no máximo 430 px de largura**, com cantos arredondados (28) e borda de 1 px na cor `card`, margem vertical 12. A **web** larga usa o layout de navegador (Seção 6.8).

### 6.2 Início

De cima para baixo:
1. Texto `mu`: saudação por horário (**Bom dia** / **Boa tarde** / **Boa noite**).
2. `h1` **Seu som**.
3. Grade de **2 cartões** (`StatCard`, espaço 10): **"42 h"** com "ouvidas este mês" e **"318"** com "músicas diferentes". Número em `gr`, 26/800; legenda em `mu`. (Valores reais vêm do histórico.)
4. `h2` **Artistas que você mais ouve** → carrossel de artistas (círculos de 96).
5. `h2` **Mais tocadas** → 4 linhas `TrackRow`.
6. `h2` **Álbuns** → carrossel de capas 96 com o nome do álbum.
- Sem servidor/login: mostrar dados locais se existirem; senão, estado vazio: "Entre ou baixe músicas para ver suas métricas aqui."

### 6.3 Buscar

- `h1` **Buscar**; campo com dica **"Músicas, artistas, álbuns ou link"**.
- Chips logo abaixo (margem 10): **Spotify** e **YT Music** (um ativo por vez; ativo = laranja).
- **Campo vazio:** `h2` **Buscas recentes** com linhas (ícone de histórico `mu` + texto). Tocar numa linha repete a busca. Abaixo, texto `mu`: "Cole um link do Spotify, Deezer ou YouTube para trazer a música ou playlist exata."
- **Texto digitado** (com debounce de ~400 ms): seções na ordem **Artistas** (carrossel circular), **Álbuns** (carrossel) e **Músicas** (linhas `TrackRow`). Artistas e álbuns vêm do Spotify/YT Music.
- **Nada encontrado:** texto `mu` "Nada encontrado para "termo". Tente outro nome ou cole um link."
- **Link colado** (começa com `http`): mostra um cartão: capa 56 + **"Playlist importada"** + `mu` "24 músicas · Spotify|Deezer|YouTube". Para música avulsa, mostra a faixa exata como `TrackRow`. No cartão da playlist: botão laranja **Adicionar músicas à playlist** (pergunta em qual playlist; baixa todas as faixas no servidor e as coloca nela). Tocar no cartão abre a playlist importada para navegar.
- Toda faixa nos resultados tem ⋮ e arrastar-para-fila.
- **Modo local (sem login):** busca nas músicas e playlists baixadas/locais; chips ocultos; card "Entre para buscar músicas no servidor".

### 6.4 Biblioteca

**Lista:** `h1` **Biblioteca**. Cada playlist: capa 56 (gradiente laranja→verde se sem imagem, com o ícone `music_note`, Seção 5.3), nome (600) e `mu` "N músicas · M pessoas" (ou "só você"; "Só neste aparelho" para locais). Playlists baixadas mostram o ícone `download_done` verde. Botão laranja **Nova playlist** no fim.

**Detalhe da playlist:**
- Botão de texto "‹ Biblioteca" (`mu`) no topo.
- Capa grande (largura total, altura máx. 200, raio 8; o usuário pode trocar a foto).
- `h1` com o nome; abaixo `mu`: **"N músicas · X min · colaboram: Você, Ana, Pedro"** (duração total somada).
- Linha de ações (espaço 10): **botão circular de play (laranja)** toca a playlist inteira · chip **Aleatório** (ícone ⇄; ligado = laranja; ligado toca embaralhado, desligado toca na ordem da playlist) · chip **Compartilhar** (copia o link da playlist; toast "Link da playlist copiado") · **botão de download** (ver 8.4).
- Linha de busca: campo **"Buscar na playlist"** e chip de **ordenação** que alterna a cada toque: **Adição** → **A–Z** → **Artista**.
- Lista de `TrackRow`, cada uma com `mu` "artista · por Fulano" (quem adicionou). ⋮ e arrastar-para-fila em todas.
- Colaboração: dono define quais usuários **veem** e quais **editam** (tela de "Pessoas" aberta pelo menu da playlist).

### 6.5 Ajustes

`h1` **Ajustes** (mesmo nome da aba). Cartões (raio 14):
- **Servidor:** endereço atual (`mu`) e "Conectado como {usuário}" em `gr` (ou "Não conectado" + botão **Entrar**). Botão **Sair**.
- **Offline:** "Músicas baixadas no aparelho: N (X GB). Sem servidor, a biblioteca local continua funcionando." com **Gerenciar downloads** e **Apagar todos os downloads**.
- **Qualidade de streaming:** valor atual (ex.: "Alta (320 kbps)"), seletor.
- Opções de download: **Baixar só no Wi-Fi** (liga/desliga, padrão ligado) e **Baixar novas músicas das playlists automaticamente** (padrão desligado).

### 6.6 Player

**Mini player:** linha com capa 40, bloco de texto (título em 600 em 1 linha; abaixo `mu` "artista · álbum" em 1 linha), botão circular **play/pause** (38, laranja). Abaixo, barra de progresso fina (3). **Tocar no mini player abre o player grande.**

**Player grande** (tela cheia, padding 18×22):
1. Cabeçalho: botão `keyboard_arrow_down` (fecha), centro `mu` **"Tocando de {playlist/álbum/Busca}"**, botão `more_vert` (mesma folha de ações).
2. Capa quadrada gigante (raio 18; margem 14 em cima e 20 embaixo).
3. `h1` título (margem inferior 2) e `mu` "artista · álbum".
4. Barra de progresso (5) **arrastável**, com tempos decorrido e total.
5. Controles, distribuídos igualmente: **Aleatório** (`shuffle`) · **Anterior** (`skip_previous`) · **Play/Pause (circular 60)** · **Próxima** (`skip_next`) · **Repetir** (`repeat`; `repeat_one` no modo uma faixa) · **Fila** (`queue_music`). Aleatório, Repetir e Fila ficam em `gr` quando ativos. Cada toque em Repetir alterna o modo (Seção 7.2) e mostra o toast "Repetir desligado" / "Repetindo tudo" / "Repetindo esta música".
6. Ao ativar **Fila**, o painel aparece **abaixo dos controles**:
   - `h2` **Sua fila** (itens adicionados manualmente). Vazia: `mu` "Vazia. Use "Adicionar à fila" e a música toca logo depois da atual."
   - `h2` **A seguir da playlist** (fila automática; mostrar as próximas 4 e permitir "ver todas").
   - Itens podem ser reordenados (arrastar) e removidos.
7. Botões extras do Spotify, que ficam para depois: letras, timer de sono, velocidade (ver Seção 13).

### 6.7 Artista e Álbum (não estão no protótipo; seguir o mesmo design)

**Artista:** cabeçalho com foto circular grande, nome (`h1`) e ouvintes, botões play (laranja) e aleatório. Abas (chips) **Populares**, **Álbuns**, **Todas as músicas**. Populares vem primeiro. **Todas as músicas** carrega **todas** as faixas do artista com **paginação por offset** (o Spotify limita a ~100 por requisição); rolagem infinita com indicador de carregamento. No topo, campo **"Buscar neste artista"** que filtra dentro da aba atual.

**Álbum:** capa grande, nome (`h1`), artista, ano e duração total; botões play e aleatório; lista de faixas numeradas; campo **"Buscar neste álbum"**.

**Playlist importada (de link):** mesma tela de detalhe da playlist, com o botão laranja **Adicionar músicas à playlist** no topo.

Todas as faixas dessas telas usam `TrackRow` (⋮ e arrastar-para-fila).

### 6.8 Layout de navegador (web a partir de 900 px)

Não está no protótipo; segue os mesmos tokens e componentes. As telas são as mesmas do celular (mesmos widgets), só a moldura muda:
- **Barra lateral** fixa de 280 px à esquerda, com 3 painéis `card` (raio 14, espaço 8, margem 8):
  1. "Bergastream" (22/800) e os itens **Início** e **Buscar** (ícone 24 + texto 15/600; ativo em `ac`).
  2. **Sua biblioteca** (abre a aba Biblioteca) com a lista de playlists (capa 48, nome 600, legenda `mu` "N músicas · M pessoas") e o botão **Nova playlist**. Ocupa o espaço que sobra.
  3. **Ajustes**.
- **Conteúdo** à direita, ocupando toda a largura restante, padding 24 em cima, 32 nas laterais e 40 embaixo. Os avisos de sessão ficam no topo do conteúdo.
- **Barra do player** fixa embaixo, altura 84, fundo `bg` com borda superior `card`: à esquerda capa 56 + título e "artista · álbum"; no centro (520 px) Aleatório · Anterior · Play/Pause (38) · Próxima · Repetir e, abaixo, tempo decorrido · barra de progresso · duração (12 `mu`); à direita o botão **Fila**. Substitui o mini player e o player grande.
- Sem barra de navegação inferior e sem mini player.
- Tela de login centralizada, largura máxima 400.

---

## 7. Lógica do player e da fila

### 7.1 Duas filas
- **Fila automática (`autoQueue`):** criada quando se toca uma playlist, álbum, artista ou resultado de busca. Ao tocar uma faixa dentro de uma lista, a fila automática passa a ser as **faixas seguintes daquela lista** (na ordem, ou embaralhadas se o modo aleatório estiver ligado; a faixa atual sai da frente).
- **Sua fila (`manualQueue`):** faixas adicionadas com **Adicionar à fila** (ou arrastando a linha). Vale a regra: **a primeira adicionada toca logo depois da atual; a segunda, depois da primeira**, ou seja, **ordem de chegada (FIFO)**.

### 7.2 Regra de "próxima"
1. Se `manualQueue` não estiver vazia, toca o primeiro item e o remove.
2. Senão, toca o próximo da `autoQueue`.
3. Se ambas acabarem: com Repetir desligado, **para** ao fim da faixa; com Repetir tudo, recomeça a lista de origem do início (refaz a `autoQueue`).
4. Com Repetir uma faixa, "próxima" automática (fim da faixa) recomeça a mesma faixa; o botão Próxima avança normalmente.

- **Anterior:** se passaram mais de 3 s da faixa, volta ao início dela; senão, volta à faixa anterior do histórico da sessão.
- **Aleatório:** reembaralha apenas a `autoQueue` (a `manualQueue` nunca é embaralhada).
- **Repetir:** desligado → tudo → uma faixa (ciclo no botão).
- Tocar uma nova lista **não apaga** a `manualQueue` (padrão do Spotify), mas oferece "Limpar fila" no painel.

### 7.3 Fonte do áudio (nesta ordem)
1. **Arquivo local baixado**, se existir (funciona sem servidor).
2. **Streaming do servidor**, se logado e com conexão: pedir ao backend para preparar a faixa (`play`), acompanhar o status ("Baixando…" visível no mini player) e iniciar o stream quando estiver pronta.
3. Senão: toast "Esta música não está baixada."

### 7.4 Plataforma
- **Android:** `audio_service` com notificação de mídia (capa, título, play/pause, anterior, próxima, barra de progresso) e tela de bloqueio; continua tocando com o app fechado ou a tela desligada; trata foco de áudio (pausa em ligação, abaixa volume com avisos).
- **Web:** sem notificação de mídia nativa no começo; usar a Media Session API se simples.
- A reprodução registra **histórico** (ao passar de ~30 s ou 50% da faixa) enviando ao servidor; offline, guardar localmente e enviar quando voltar a conexão.

---

## 8. Modo offline e downloads locais (MUITO IMPORTANTE)

Objetivo: o usuário baixa **playlists inteiras** para o celular/PC e tudo (**áudio, metadados e imagens**) fica disponível **sem servidor**.

### 8.1 O que é salvo no aparelho, por faixa
- **Áudio** (arquivo, na pasta de documentos do app).
- **Metadados:** título, artista, álbum, duração, ISRC, ids externos, ano.
- **Imagem da capa** (arquivo local; a UI usa o arquivo local antes de qualquer URL).
- Por playlist: nome, descrição, **foto da playlist**, ordem das faixas, **quem adicionou cada faixa**, colaboradores (nome e papel).

### 8.2 Estados
- **Faixa:** `naoBaixada → naFila → baixando → baixada` ou `falhou`.
- **Playlist:** `naoBaixada`, `baixando (x/y)`, `parcial`, `baixada`.

### 8.3 Regra de permanência local (espelha a do servidor)
- Um arquivo de áudio fica no aparelho **enquanto existir pelo menos uma playlist baixada que contém a faixa** (contagem de referências).
- Remover o download de uma playlist apaga apenas as faixas que não estão em nenhuma outra playlist baixada.
- Faixa removida de uma playlist baixada (no servidor) é removida do aparelho na próxima sincronização, respeitando a mesma regra.

### 8.4 Botão de download na playlist (detalhe da playlist, na linha de ações)
Disponível **só em Android/Windows/Linux e só logado** (na web o botão não existe).

| Estado | Aparência | Ao tocar |
|---|---|---|
| Não baixada | Ícone `download` + texto **Baixar no aparelho** | Confirma ("Baixar N músicas, cerca de X MB?") e inicia |
| Baixando | Anel de progresso verde + **"Baixando 3/12"** | Abre opções: **Pausar** / **Cancelar** |
| Parcial (falhas ou novas faixas) | Ícone `download` + **Baixar restantes (2)** | Baixa o que falta |
| Baixada | Ícone `download_done` verde + **Baixada** | Opções: **Remover download** |

Também: menu da playlist com a opção **Atualizar download** (baixa as faixas novas e remove as retiradas). Se a playlist mudou no servidor, mostrar o selo "2 novas músicas".

### 8.5 Gerenciador de downloads
- **2 downloads simultâneos**, em fila; retomar após fechar o app; tentar de novo (até 3 vezes, com espera crescente) em caso de falha de rede.
- Respeita **"Baixar só no Wi-Fi"**.
- Em Android, roda em **segundo plano** com notificação de progresso ("Baixando "Roadtrip": 3 de 12").
- Se a faixa ainda não estiver pronta no servidor, o app pede ao servidor para prepará-la e consulta o status até ficar pronta, depois baixa o arquivo.
- Baixar também a **imagem da capa** e salvar os metadados no banco local, **na mesma operação** (se o áudio falhar, não marcar como baixada).
- Validar o arquivo após baixar (tamanho esperado) antes de marcar `baixada`.
- Tela **Gerenciar downloads** (em Ajustes): lista de playlists baixadas com tamanho, espaço total usado e botão de remover cada uma.

### 8.6 Uso offline
- Aba **Biblioteca** lê do banco local quando não há servidor; playlists baixadas funcionam normalmente (tocar, embaralhar, buscar dentro dela, ordenar, ⋮, fila).
- Funcionalidades que alteram o servidor (adicionar/remover faixas de playlists do servidor, colaborar, compartilhar) ficam desabilitadas offline com toast explicativo. Playlists **locais** podem ser editadas offline.
- Ao entrar com login em um aparelho que tem playlists locais, perguntar: "Enviar suas playlists locais para o servidor?" (Enviar / Manter só aqui).

### 8.7 Dados locais e sincronização (PROPOSTA, validar antes de implementar)

**Situação hoje:** só o download offline está definido (8.1–8.6), e o banco local (Seção 10) existe só no app. Não há regra para guardar metadados de conteúdo **não baixado**, nem protocolo de sincronização (a Seção 9 cita apenas "alteração de playlists"). Sem isso, toda tela buscaria tudo no servidor a cada abertura.

**Proposta:**
1. **Local primeiro:** as telas leem do banco local e mostram na hora; o servidor atualiza o banco em segundo plano e a tela se atualiza sozinha.
2. **O que fica local (inclusive na web):**
   - Biblioteca do usuário: playlists (nome, foto, ordem, quem adicionou, colaboradores) e os metadados das faixas delas.
   - Artistas e álbuns visitados (com validade, ex.: 7 dias), métricas da tela inicial (última resposta), histórico de buscas e reproduções pendentes.
   - Imagens em cache de disco (app) ou Cache API do navegador (web).
   - **Não** guardar resultados de busca (só os termos). Áudio só no app e só o que foi baixado (8.1).
3. **Banco:** Drift em todas as plataformas (SQLite nativo no app; SQLite WASM na web). Um código só.
4. **Sincronização incremental (backend novo):** playlists e itens ganham `updated_at` e remoções viram registros de exclusão; `GET /api/sync?since=<cursor>` devolve só o que mudou (playlists, itens, faixas, ids removidos) e um cursor novo. Chamado ao abrir o app, ao reconectar e periodicamente em primeiro plano, nunca a cada tela. Metadados de faixa quase não mudam: cache sem validade.
5. **Escritas offline** (playlists locais, edições) vão para uma fila enviada ao reconectar; adicionar/remover faixa são operações idempotentes.
6. **Impacto no plano:** o banco local (hoje no Passo 9) passaria para antes do Passo 8, e o backend precisaria de `/api/sync` antes do Passo 8 (Biblioteca já nasce lendo do banco local).

---

## 9. Contrato da API (CONFIRMAR NO BACKEND NO PASSO 0)

O backend já existe. Esta é a lista do que o app **precisa**. No Passo 0, mapear cada item para o endpoint real e marcar **existe / existe com outro formato / falta**. Nunca assumir.

| Área | O que o app precisa |
|---|---|
| Auth | login (usuário e senha → tokens), renovar token, perfil (`me`), logout, (cadastro, se permitido) |
| Busca | por texto em Spotify e YT Music, retornando **faixas, artistas e álbuns**; resolver link (Spotify/Deezer/YouTube → faixa ou playlist com suas faixas) |
| Artista | dados, mais tocadas, álbuns, **todas as faixas com paginação (offset/limit)**, busca dentro do artista |
| Álbum | dados e faixas, busca dentro do álbum |
| Reprodução | "preparar faixa" (com a faixa do resultado), status (`baixando/pronta/erro`), **stream com HTTP Range**, **arquivo completo para download** |
| Playlists | listar, criar, editar, apagar; faixas com **quem adicionou e quando**; reordenar; foto (upload); colaboradores e permissões (ver/editar); link de compartilhamento; "adicionar faixas de link importado" |
| Histórico | registrar reprodução; estatísticas (horas no mês, músicas diferentes, artistas/faixas/álbuns mais ouvidos) |
| Sincronização | alteração de playlists (para o "2 novas músicas") |

**Pontos críticos (verificar com atenção):**
1. **Autenticação do stream no web.** ✅ Resolvido: `POST /api/tracks/{id}/stream-token` gera um token curto só daquela faixa, usado em `/stream?t=...` (ver `docs/API_MAP.md`).
2. **Endpoint de download de arquivo completo** (para o modo offline), com autenticação.
3. **Paginação de todas as faixas do artista** (offset).
4. **Imagens (capas):** URL acessível pelo app (via proxy do servidor, por causa de CORS na web).

Toda chamada passa por **interfaces de repositório** (`AuthRepository`, `SearchRepository`, `PlaybackRepository`, `PlaylistRepository`, `HistoryRepository`). Cada interface tem uma **implementação fake** (dados do protótipo) para desenvolver e testar a interface sem depender do servidor, e a implementação real.

---

## 10. Banco local (Drift; não existe na web)

Tabelas:
- `local_tracks`: `id` (id do servidor ou UUID local), `title`, `artist`, `album`, `duration_seconds`, `isrc`, `cover_url`, `cover_path`, `audio_path`, `size_bytes`, `download_state`, `downloaded_at`, `last_played_at`.
- `local_playlists`: `id`, `server_id` (nulo se local), `name`, `cover_path`, `is_local_only`, `owner`, `updated_at`, `download_state`.
- `local_playlist_items`: `playlist_id`, `track_id`, `position`, `added_by`, `added_at`.
- `local_collaborators`: `playlist_id`, `user_name`, `role`.
- `search_history`: `id`, `term`, `source`, `created_at`.
- `pending_plays`: reproduções feitas offline, a enviar ao servidor.
- `app_state` (chave/valor): modo de acesso, preferências, último cache de métricas da tela inicial.

Migrações do Drift versionadas desde o início.

---

## 11. Passos de implementação

> Em **todos** os passos: `flutter analyze` limpo, `flutter test` verde, relatório no formato da Seção 0, e **pare** para validação.

### Passo 0: Reconhecimento (sem código de app)
**Tarefas**
- Ler o backend existente e produzir `docs/API_MAP.md` com cada item da Seção 9: endpoint real, método, corpo, resposta, autenticação e status (existe / formato diferente / falta).
- Listar **pendências do backend** (principalmente os pontos críticos da Seção 9).
- Confirmar: Flutter instalado (`flutter doctor`), emulador Android funcionando, Chrome disponível.
**Aceite:** `docs/API_MAP.md` completo; lista de pendências entregue; `flutter doctor` sem erros para Android e web.

### Passo 1: Projeto, tema e componentes
**Tarefas**
- Criar o projeto (`com.bergastream.app`), pastas da Seção 4, lints, plataformas Android e Web ativas, `uses-material-design: true`, `minSdk 24` e permissões Android da Seção 3.
- Incluir a fonte Bricolage Grotesque nos assets (400/600/800).
- Implementar o **tema escuro e claro** com os tokens da Seção 5.1, tipografia da 5.2 e medidas da 5.3.
- Implementar os componentes da Seção 5.4 (`Cover` com gradiente e inicial, `TrackRow`, `AppChip`, `PrimaryButton`, `AppTextField`, `AppToast`, `TrackActionsSheet`, `StatCard`, `HorizontalShelf`, etc.).
- Criar uma **tela de galeria** (`/dev/gallery`, só em debug) mostrando todos os componentes nos dois temas.
**Testes:** testes de widget para `Cover` (matiz sempre entre 18 e 150, inicial correta), `TrackRow` (estado tocando em verde, ícone de baixada, ⋮), `AppChip` (ativo/inativo), `AppToast` (some após 1,5 s). **Golden tests** da galeria nos dois temas, com as fontes reais carregadas em `test/flutter_test_config.dart` (sem isso o texto vira blocos).
**Aceite:** a galeria no emulador é **visualmente idêntica** ao protótipo (cores, tamanhos, raios).

### Passo 2: Navegação e shell, com dados fake
**Tarefas**
- `go_router` com shell e as 4 abas (Seção 6.1); barra de navegação; mini player visível com uma faixa fake; layout centralizado de 430 px em telas largas.
- Telas **Início, Buscar, Biblioteca e Ajustes** montadas com **dados fake** idênticos aos do protótipo (mesmas faixas e textos), sem lógica real.
- Troca de aba preserva a posição de rolagem e o estado da tela.
**Testes:** widget test de troca de abas; teste do shell em largura de 360 e de 1200.
**Aceite:** lado a lado com o protótipo, as 4 telas são iguais.

### Passo 3: Autenticação e modos de acesso
**Tarefas**
- Implementar a Seção 2 completa: tela de login (Seção 2.2), máquina de estados da sessão (2.3), armazenamento seguro, interceptor de renovação de token, **redirecionamento do `go_router`** conforme o estado.
- **Web:** nenhuma rota abre sem sessão. **Mobile/desktop:** botão **Continuar sem entrar** e modo local.
- `OfflineBanner` e os avisos da Seção 2.4 (sessão expirada, servidor indisponível, busca local).
- Tela de Ajustes: servidor, usuário, **Entrar/Sair** (com a pergunta de manter ou apagar downloads).
- Usar `AuthRepository` (fake e real).
**Testes (unitários):** todas as transições de estado da sessão; redirecionamento na web (sem sessão → login) e no mobile (modo local permitido); falha de renovação → `sessaoExpirada` sem deslogar. **Widget:** erros do login exibidos; botão "Continuar sem entrar" só aparece fora da web.
**Aceite:** manual, no Android: abrir sem login e ver a interface; abrir a busca e ver o card "Entre para buscar…"; logar e ver o estado conectado; matar o servidor e ver o aviso "Servidor indisponível…"; no Chrome, não é possível ver nada sem login.
**Autenticação real** (`/api/auth/*`, JWT + refresh com rotação) entrou junto com o Passo 4. O `FakeAuthRepository` ficou só para os testes. Em debug, Ajustes tem o cartão "Desenvolvimento" para simular servidor indisponível e sessão expirada (esta estraga os tokens e passa pelo fluxo real). A detecção real do servidor fica no Passo 11.

### Passo 4: Cliente de API e modelos
**Tarefas**
- `dio` com base URL configurável, interceptors (token, renovação, erros padronizados, timeout), modelos com `json_serializable`, implementações **reais** dos repositórios conforme `API_MAP.md`.
- Mapeamento de erros: rede, 401, 4xx, 5xx → mensagens claras em português.
**Testes:** testes de cada repositório com `dio` simulado (respostas reais copiadas do backend); teste da renovação de token em chamadas concorrentes (só uma renovação).
**Aceite:** manual: login real no servidor e chamada de uma busca real exibida em log/tela de debug.
**Feito além do pedido:** a aba Buscar já usa a busca real (só faixas, com espera de 400 ms, "Buscando…", erro com "Tentar de novo"). O Passo 6 completa artistas/álbuns, histórico real e links, que dependem de pendências do backend.

### Passo 5: Player (motor, fila, mini e player grande)
**Tarefas**
- Motor com `just_audio` + `audio_service`: tocar, pausar, buscar posição, anterior/próxima, repetir, aleatório.
- **Fila dupla** (Seção 7): `autoQueue` e `manualQueue`, regra de "próxima", ações "Adicionar à fila" (FIFO).
- Fonte do áudio na ordem da Seção 7.3 (nesta fase: servidor; arquivo local entra no Passo 9).
- **Mini player** (6.6) e **player grande** (6.6) idênticos ao protótipo, com painel de fila (Sua fila / A seguir da playlist), reordenar e remover.
- Android: notificação de mídia, tela de bloqueio, tocar com o app fechado, foco de áudio.
- Registro de histórico de reprodução.
**Testes (unitários, o mais importante):** fila — manual vem antes da automática; duas adições manuais mantêm a ordem de chegada; aleatório embaralha só a automática; anterior (>3 s volta ao início); repetir (3 modos); tocar nova lista preserva a fila manual. **Widget:** mini player abre o grande; botões alteram o estado.
**Aceite:** manual: tocar uma faixa real do servidor; minimizar o app e continuar tocando; controlar pela notificação; adicionar 2 faixas à fila e ouvir a ordem correta.

### Passo 6: Busca
**Tarefas**
- Tela de busca completa (6.3): chips, histórico local de buscas, resultados em **Artistas / Álbuns / Músicas**, debounce, estado vazio, "nada encontrado".
- **Colar link** (Spotify/Deezer/YouTube): faixa avulsa ou cartão de playlist importada com o botão **Adicionar músicas à playlist** (escolher a playlist de destino).
- `TrackActionsSheet` funcionando (Compartilhar com a pergunta "Link do Spotify" ou "Link do app"; Adicionar à playlist; Adicionar à fila; Ir para o álbum; Ir para o artista) e **arrastar para adicionar à fila**.
- Modo local (sem login): busca nas baixadas/locais e card "Entre para buscar músicas no servidor".
**Testes:** debounce (uma chamada para digitação rápida); detecção de link; histórico (sem duplicatas, mais recentes primeiro); widget do sheet e do gesto de arrastar.
**Aceite:** manual: buscar "queen", alternar Spotify/YT Music, abrir o ⋮, adicionar à fila, arrastar uma linha, colar um link de playlist.

### Passo 7: Artista e Álbum
**Tarefas**
- Telas da Seção 6.7. **Artista:** populares primeiro, álbuns, aba **Todas as músicas** com paginação por offset e rolagem infinita; busca dentro da página. **Álbum:** faixas e busca interna.
- Navegação a partir dos resultados, do ⋮ ("Ir para o artista/álbum") e do carrossel da tela inicial.
**Testes:** paginação (carrega páginas sucessivas sem repetir faixas; para quando acabam); filtro interno; widget de estados de carregamento e erro.
**Aceite:** manual: artista com mais de 100 músicas mostra **todas** na aba "Todas as músicas".

### Passo 8: Biblioteca e playlists
**Tarefas**
- Lista de playlists e **detalhe** idêntico ao protótipo (6.4): capa (com troca de foto), nome, "N músicas · X min", play, **Aleatório**, **Compartilhar**, busca interna, **ordenação** (Adição → A–Z → Artista), "por Fulano" em cada faixa.
- Criar, renomear e apagar playlist; adicionar/remover faixas (pelo ⋮ e pelo link importado); reordenar.
- **Colaboração:** tela "Pessoas" (ver/editar por usuário) e exibição de quem adicionou cada faixa.
- **Playlists locais** (modo sem login), marcadas "Só neste aparelho".
**Testes:** ordenação; busca interna; duração total; permissão (quem só vê não edita); aleatório vs. ordem; playlist local criada sem login.
**Aceite:** manual: criar playlist, adicionar faixas da busca, tocar em ordem e embaralhado, ordenar, buscar dentro dela.

### Passo 9: Banco local e downloads (modo offline)
**Tarefas**
- Banco Drift (Seção 10) com migrações.
- **Gerenciador de downloads** (8.5): fila com 2 simultâneos, retomada, tentativas, Wi-Fi apenas, notificação em segundo plano, validação do arquivo, capa e metadados salvos junto.
- **Botão de download na playlist** (8.4) com todos os estados; selos de faixa baixada nas linhas.
- **Permanência local** com contagem de referências (8.3).
- **Player usa o arquivo local primeiro** (7.3).
- **Biblioteca e busca local** funcionando 100% sem servidor (8.6); tela **Gerenciar downloads** em Ajustes.
- Imagens: a UI usa a capa local antes da URL.
**Testes (críticos):** contagem de referências (remover download de uma playlist não apaga faixa usada em outra); estados da playlist (não baixada → baixando → baixada, parcial quando falha); retomar após reinício; faixa só vira "baixada" com áudio válido **e** metadados e capa salvos; busca local; player prefere local.
**Aceite:** manual, no Android: baixar uma playlist; ligar o **modo avião**; abrir o app e **tocar a playlist inteira**, ver as capas e os nomes de quem adicionou; buscar dentro das baixadas; remover o download e confirmar que o espaço é liberado.

### Passo 10: Início e Ajustes completos
**Tarefas**
- Tela inicial com **métricas reais** do histórico (horas no mês, músicas diferentes, artistas, mais tocadas, álbuns), cache da última resposta para uso offline.
- Ajustes completos (6.5): servidor, qualidade, downloads, Wi-Fi apenas, atualização automática de playlists baixadas.
**Testes:** cálculo/formatação das métricas; exibição do cache offline.
**Aceite:** manual: métricas batem com o histórico de reprodução.

### Passo 11: Offline-first e sincronização
**Tarefas**
- Detecção de rede e do servidor (`connectivity_plus` + verificação do servidor); banners e transição suave online/offline (Seção 2.3 e 2.4).
- Envio das reproduções pendentes (`pending_plays`) ao reconectar.
- **Atualizar download** e selo "N novas músicas"; opção automática (se ativada, apenas em Wi-Fi).
- Ao entrar com login, oferta de enviar playlists locais ao servidor.
**Testes:** envio de pendentes em ordem e sem duplicar; sincronização de faixas adicionadas/removidas respeitando a contagem de referências.
**Aceite:** manual: tocar offline, reconectar e ver o histórico chegar ao servidor; alterar uma playlist baixada pelo web e ver o selo no app.

### Passo 12: Web (base)
**Tarefas**
- Build web: login obrigatório, layout centralizado de 430 px, **stream autenticado** (conforme a solução definida no Passo 0), imagens via proxy do servidor, botões de download e itens exclusivos do mobile **ocultos**.
- `Dockerfile` (build do Flutter web + nginx) e entrada no `docker-compose` para publicar atrás do proxy reverso.
- Rota de fallback (SPA) configurada no nginx.
**Testes:** teste de integração no Chrome: sem sessão → login; com sessão → busca e reprodução.
**Aceite:** manual: abrir o domínio, logar, buscar, tocar. Recarregar a página mantém a sessão. Sem login, nada abre.

### Passo 13: Release Android e preparação Windows/Linux
**Tarefas**
- Android: ícone, nome, assinatura, `flutter build apk --release` (e `appbundle`), teste em aparelho físico (reprodução em segundo plano, bateria, notificações).
- Habilitar Windows/Linux: `just_audio_media_kit`, caminhos de arquivo, tamanho mínimo de janela; mesmo comportamento da matriz da Seção 2.1.
- Checklist final da Seção 12.
**Aceite:** APK instalado em aparelho real passando por **todo** o checklist.

**Decisões tomadas no Passo 13 (out/2026)**
- **Layout no Windows/Linux:** janela com 900 px ou mais usa o layout de navegador (Seção 6.8), mas com as regras do app (uso sem login, downloads, biblioteca local). Janela mais estreita usa o layout de celular na largura toda. Tamanho mínimo da janela: 360×600.
- **Distribuição:** GitHub Releases do repositório `Agelinena/bergatrix`, tag `bergastream-vX.Y.Z`, gerada pelo GitHub Actions (APK universal assinado, `.zip` do Windows, `.tar.gz` do Linux). Ver `docs/RELEASE.md`.
- **Atualização pelo app:** ao abrir (no máximo a cada 20 h) e em Ajustes → "Verificar atualizações". Android baixa e abre o instalador; Windows/Linux salvam em Downloads e abrem a pasta; sempre há "Ver no GitHub" e "Agora não" (não insiste na mesma versão).
- **Publicação:** Traefik modelo B (`docs/modelos-labels-traefik.md`): web atrás do Authentik fora de casa; os apps usam `/api-access-bypass/api` (só a API, com o login próprio). O app descobre o prefixo sozinho a partir de `bergastream.daberga.com`. Ver `docs/DEPLOY.md`.
- **Usuários:** criados pela CLI (`docs/USUARIOS.md`); cadastro aberto desligado.

---

## 12. Checklist final de aceite

- [ ] Design idêntico ao protótipo nas 4 abas, mini player, player grande, folha de ações e toasts (escuro e claro).
- [ ] **Web:** impossível acessar qualquer tela sem login.
- [ ] **Mobile/desktop:** abre sem login; biblioteca local, playlists locais, músicas baixadas e busca local funcionam; busca no servidor e streaming só logado.
- [ ] Login, renovação de token, sessão expirada e servidor indisponível tratados com os avisos corretos.
- [ ] Busca: Spotify/YT Music, artistas, álbuns, músicas, histórico, colar link (faixa e playlist) e **Adicionar músicas à playlist**.
- [ ] Artista: populares, álbuns e **todas as músicas** (mais de 100, com paginação) e busca interna.
- [ ] Playlist: capa trocável, métricas, play, aleatório, compartilhar, busca interna, ordenação, "por Fulano", ⋮, arrastar para fila, colaboração.
- [ ] Fila: **Sua fila (FIFO) antes da fila automática**; aleatório só na automática.
- [ ] **Download de playlist para o aparelho** com áudio, metadados e imagens; tocar tudo offline em modo avião; contagem de referências correta.
- [ ] Player em segundo plano no Android com notificação e tela de bloqueio.
- [ ] `flutter analyze` e `flutter test` limpos; testes de fila, sessão, downloads e paginação presentes.

---

## 13. Fora do escopo agora (não implementar)

Rádio, letras sincronizadas, timer de sono, velocidade de reprodução, equalizador, atividade dos amigos, "ouvir junto", retrospectiva anual, importar biblioteca do Spotify, painel de admin, iOS/macOS.