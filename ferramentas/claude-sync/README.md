# claude-sync

App de desktop que guarda as conversas do Claude Code no Nextcloud (`storange`) e as traz em qualquer PC. É um executável só: abra, entre no Nextcloud, ative a pasta e pronto. Ele fica em segundo plano, sincronizando.

## Como funciona

```
Claude Code ──grava──▶ ~/ClaudeSync  ◀──sincroniza──▶  Nextcloud: Claude/
                      (CLAUDE_CONFIG_DIR)             ├── projects/<projeto>/   conversas e memória
                                                      └── global/               CLAUDE.md, agents, commands, skills
```

- **A pasta do Claude passa a ser a pasta sincronizada.** Ao ativar, o app grava a variável de usuário `CLAUDE_CONFIG_DIR` apontando para ela (padrão: `~/ClaudeSync`).
  - O Claude Code guarda ali tudo o que guardaria em `~/.claude`: conversas, memória, configurações, login.
  - Os seus projetos continuam onde estão; só os dados do Claude mudam de lugar.
  - O que já existe em `~/.claude` e `~/.claude.json` é copiado para a pasta nova, sem sobrescrever nada.
- **Sobe só o que faz sentido levar:**
  - sempre: as conversas e a memória de cada projeto;
  - por escolha: `CLAUDE.md`, `agents/`, `commands/`, `skills/` e, opcionalmente, `settings.json`;
  - nunca: credenciais (`.credentials.json`, `.claude.json`), caches, plugins e o `file-history`.
- **Conversas por projeto, não por caminho.** O Claude Code nomeia a pasta de cada projeto pelo caminho absoluto (`c--Users-lucas-src-bergatrix`), que muda de um PC para outro. No Nextcloud elas ficam pelo nome do projeto (`projects/bergatrix/`). Num PC novo, o app descobre onde o projeto está:
  1. pelos projetos que o Claude Code já abriu neste PC (o `.claude.json`): basta abrir o Claude Code no projeto uma vez;
  2. ou pelo vínculo feito na interface ("caminho do projeto neste PC").
- **Login pelo Nextcloud (Login Flow v2),** como o app de desktop dele:
  - o navegador abre o login, que passa pelo Authentik;
  - o app recebe uma senha de app própria, que aparece em *Configurações pessoais → Segurança → Dispositivos e sessões*;
  - "Desconectar" revoga essa senha no servidor.
- **Senha guardada com criptografia do sistema:** DPAPI no Windows (`%APPDATA%\claude-sync\credential.dpapi`, presa à sua conta do Windows), Keychain no macOS, Secret Service no Linux. Nunca aparece em texto puro no disco.
- **Sincronização:**
  - **Envio:** a cada 5 s, o app olha a pasta local. Um arquivo só sobe depois de ficar 3 s parado, porque o Claude grava a conversa linha a linha.
  - **Recebimento:** a cada 30 s (configurável), o app consulta o Nextcloud. O Nextcloud propaga o etag para as pastas acima, então uma volta sem mudanças custa uma única consulta.
- **Nunca apaga nada,** nem lá nem aqui. Se a mesma conversa mudou nos dois PCs:
  - se uma versão continua a outra (o caso normal), fica a maior;
  - se divergiram de verdade, as duas ficam. A do Nextcloud vira `<sessão>.conflito-<data>.jsonl`, e o `/resume` mostra as duas.
- **Interface só local** (`http://127.0.0.1:47823`):
  - confere o `Host` (contra DNS rebinding) e exige um cabeçalho próprio em toda ação (contra outros sites);
  - CSP `default-src 'self'`.
- **Uma cópia por vez:** abrir o app de novo só abre a interface da cópia que já está rodando.
- **Ícone na bandeja** (a setinha da barra de tarefas no Windows; a área de notificação no Linux):
  - o ponto no canto mostra o estado: verde sincronizado, amarelo sincronizando, vermelho sem conexão, cinza falta configurar;
  - clique abre a interface; o menu tem *Sincronizar agora* e *Fechar*;
  - no Linux com GNOME, precisa da extensão *AppIndicator*. No macOS não há ícone: a bandeja dele exigiria compilar com cgo.

### Etiqueta do PC

A cada mensagem, o Claude recebe de qual PC ela veio, por exemplo `[PC: notebook-casa · windows · DESKTOP-123]`. Assim ele não confunde ambientes.
- O nome do PC se escolhe em *Opções* (padrão: o nome da máquina), e a etiqueta pode ser desligada lá.
- Funciona por um hook `UserPromptSubmit` que o app grava no `settings.json` da pasta do Claude. O hook roda `claude-sync tag`, que leva uns 70 ms e só imprime a etiqueta. A saída do hook entra como contexto da mensagem.
- O hook aponta para o executável deste PC. Se o `settings.json` for sincronizado, o app tira o hook antes de enviar e põe o deste PC ao receber: um PC nunca recebe o hook de outro.
- Se o executável mudar de lugar, abra o app de novo: ele atualiza o caminho no hook.

### Pasta no Nextcloud

Padrão: `Claude/`. Para trocar, use *Nextcloud → Trocar*, navegando pelas pastas de lá ou digitando um caminho (ex.: `Backups/Claude`).
- **Mover (padrão):** leva tudo da pasta atual para a nova e deixa na antiga um aviso (`.claude-sync-movido.json`) apontando a nova. Os outros PCs leem o aviso na próxima volta e passam a usar a nova sozinhos, sem baixar nada de novo.
- **Sem mover:** só este PC passa a usar a outra pasta. A atual fica como está, e cada PC precisa ser trocado na própria interface.

## Usar

1. Pegue o executável do seu sistema, que está nesta pasta: clone o repositório ou baixe pelo GitHub (abra o arquivo → *Download raw file*). Depois é só abrir.
   - **Windows:** [`claude-sync-windows-amd64.exe`](claude-sync-windows-amd64.exe). O SmartScreen avisa na primeira vez, porque o binário não é assinado: *Mais informações → Executar assim mesmo*.
   - **macOS (Apple Silicon):** [`claude-sync-darwin-arm64`](claude-sync-darwin-arm64). Rode `chmod +x` se baixou pelo navegador; depois, botão direito → *Abrir* (Gatekeeper).
   - **Linux:** [`claude-sync-linux-amd64`](claude-sync-linux-amd64). Rode `chmod +x` se baixou pelo navegador. Para guardar a senha, precisa do `secret-tool` (`libsecret-tools`).
2. **Nextcloud:** informe `https://storange.<domínio>`, clique em *Entrar pelo Nextcloud* e depois em *Conceder acesso* na aba que abrir.
3. **Pasta:** confira o caminho e clique em *Ativar*.
4. **Feche e abra de novo o VS Code e os terminais.** Os programas que já estavam abertos não veem a variável nova, e sessões abertas antes continuam na pasta antiga.
5. Em *Opções*, ligue *Abrir junto com o sistema*.

Num segundo PC, faça o mesmo. Abra o Claude Code dentro do projeto, e as conversas dele chegam em poucos segundos. Use `/resume` para continuar. Se o projeto aparecer como "só no Nextcloud", vincule o caminho dele na interface.

**Desativar** remove a variável: o Claude Code volta a usar `~/.claude` depois de reaberto. A pasta sincronizada fica onde está, e ativar de novo continua de onde parou.

## Compilar

```
ferramentas/claude-sync/
├── claude-sync-windows-amd64.exe   o app (versionado no git)
├── claude-sync-darwin-arm64
├── claude-sync-linux-amd64
└── codigo/                         código-fonte (Go) e o build.sh
```

```bash
./ferramentas/claude-sync/codigo/build.sh                 # num container golang:1.23.4 (não precisa de Go)
GO=go ./ferramentas/claude-sync/codigo/build.sh           # com Go 1.23+ instalado
TARGETS="windows/arm64 darwin/amd64" ./ferramentas/claude-sync/codigo/build.sh   # outros alvos
```

O build roda `go vet` e `go test` e grava os executáveis nesta pasta, por cima dos anteriores. Depois é só commitar.
- Sem cgo, então os binários são estáticos. Dependência só para a bandeja: `fyne.io/systray` (com `godbus/dbus` no Linux).
- No Windows, `-H windowsgui` (sem janela de console).
- A versão sai da tag `claude-sync-vX.Y.Z`, de `VERSION=...` ou, sem nenhuma das duas, do commit.
- Cada executável tem uns 6,5 MB e fica no histórico do git a cada recompilação: recompile só quando o código mudar.

## Arquivos

| Onde | O quê |
|---|---|
| `%APPDATA%\claude-sync\` (Windows), `~/Library/Application Support/claude-sync/` (macOS), `~/.config/claude-sync/` (Linux) | `config.json` (servidor, usuário, pastas, nome do PC, opções), `state.json` (o que já foi sincronizado), `claude-sync.log`, e no Windows a senha cifrada |
| `settings.json` da pasta sincronizada | O hook `UserPromptSubmit` da etiqueta (só neste PC) |
| A pasta sincronizada | A pasta do Claude Code (`CLAUDE_CONFIG_DIR`) |
| Windows: `HKCU\Environment` e `HKCU\...\Run` | A variável e o início automático |
| macOS: `~/.zprofile`, `~/.bash_profile`, `launchctl`, `~/Library/LaunchAgents/com.bergatrix.claude-sync.plist` | A variável (para terminais e apps gráficos) e o início automático |
| Linux: `~/.profile`, `~/.config/environment.d/50-claude-sync.conf`, `~/.config/autostart/claude-sync.desktop` | A variável e o início automático |

## Segurança

- As conversas têm tudo o que passou pelo Claude: trechos de código, saídas de comandos e, às vezes, conteúdo de `.env`.
  - No Nextcloud, elas ficam em `${USERDATA_PATH}/nextcloud/data`, no NAS, **sem cifra**.
  - O backup do Bergakup leva essa pasta cifrada para o B2.
  - Não compartilhe a pasta `Claude/`.
- **PC perdido:** revogue a senha de app dele em *Dispositivos e sessões*. Ela só dá acesso aos arquivos da sua conta.
- **Limites conhecidos:**
  - Dois projetos com o mesmo nome de pasta se misturam no Nextcloud. Para separar, use `aliases` no `config.json`: `{"C:/trabalho/bergatrix": "bergatrix-trabalho"}`.
  - O nome que o Claude Code dá à pasta de um projeto com caminho muito longo pode não bater com o calculado pelo app. Nesse caso, a conversa aparece depois da primeira mensagem no projeto (o app então lê o caminho de dentro dela).
