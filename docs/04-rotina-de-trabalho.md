# Rotina de trabalho

O que fazer antes, durante e depois de qualquer mudança no Bergatrix ou num app, por uma pessoa ou numa conversa com o Claude Code. O [`CLAUDE.md`](../CLAUDE.md) da raiz aponta para cá, então toda conversa segue estas regras.

## Antes

1. **Atualizar o repositório:**
   ```bash
   git pull && git submodule update --init
   ```
   Se houver mudança local que não é sua, pare e pergunte antes de mexer.
2. **Saber onde está.** As máquinas não têm as mesmas ferramentas:

   | Máquina | Tem | Não tem |
   |---|---|---|
   | Notebook (Linux) | Docker, Flutter (pelo Docker), graphify | – |
   | PC do trabalho (Windows) | git, gh, Git Bash | Docker, Python, Go, Flutter, graphify |
   | Servidor | Docker, as stacks de verdade | – (não é lugar de teste) |

   Teste que precisa de Docker é no notebook. No PC do trabalho só dá para editar, revisar e publicar.
3. **Saber onde a mudança mora:**
   - **Código de um app com repositório próprio** (`03-apps/bergastream`, `berganews`, `doberga`, `transcriptor`, `drop`, `legendarr`): vai no repositório do app. Aqui só se atualiza o ponteiro do submódulo ([03-padrao-stacks.md](03-padrao-stacks.md#apps-com-repositório-próprio-submódulo)).
   - **O que é só deste servidor** (rotas, redes, rótulos, versões de imagem de terceiros, docs): vai no Bergatrix.
4. **Ler o que já existe:** o documento da área em `docs/` e o compose da stack. O compose vale mais que o documento.

## Durante

### Testes com Docker

Um teste não pode deixar nada para trás nem encostar no que está no ar.

- **Nunca no servidor.** O servidor roda as stacks de verdade, com os mesmos `container_name` que o compose do teste usaria.
- **Projeto com prefixo `teste-`:** `docker compose -p teste-<app> …`. É assim que o [`limpar-testes.sh`](../00-infrastructure/limpar-testes.sh) acha o que apagar.
- **Dados em `~/.cache/bergatrix-teste/<app>`.** Nunca na pasta temporária do Claude (`/tmp/claude-*`): o Docker recria a pasta como root a cada boot, e o Claude Code para de funcionar. Nunca nas raízes de verdade (`APPDATA_PATH`, `CACHE_PATH`, `MEDIA_PATH`, `USERDATA_PATH`).
- **`restart: "no"`** em todos os serviços do teste, para nada voltar sozinho depois de um reboot.
- **Portas altas e livres** (ex.: 18080), para não brigar com nada que esteja rodando.
- **Segredos de teste**, gerados na hora. Nunca copie um `.env` real para o teste.

Exemplo:

```bash
mkdir -p ~/.cache/bergatrix-teste/berganews
cd 03-apps/berganews
APPDATA_PATH=~/.cache/bergatrix-teste/berganews WEB_PORT=18080 \
  docker compose -p teste-berganews up -d --build
```

### Commits e repositórios

- **Commit e push só com autorização** de quem pediu a mudança.
- **E-mail dos commits:** o pessoal, nunca o do trabalho. Em repositório novo ou máquina nova, confira `git config user.email` contra os últimos commits (`git log -3 --format=%ae`).
- **Nunca no git:** `.env`, chaves (`*.jks`, `key.properties`), dados de volume, backups.
- **Repositórios públicos** (os dos apps, e o Bergatrix enquanto for público): sem domínio, IP, e-mail ou segredo reais. Use `example.com`.
- **Um assunto por commit.** Não misture arquivo que não tem a ver com a mudança.
- Mudou uma stack? No **mesmo commit**: o [`stacks.txt`](../00-infrastructure/stacks.txt), o [mapa de armazenamento](02-armazenamento.md#mapa-atual-por-stack) e a [tabela de stacks](01-infraestrutura.md#stacks).

## Depois

1. **Limpar os testes:**
   ```bash
   ./00-infrastructure/limpar-testes.sh --ver   # o que vai sair
   ./00-infrastructure/limpar-testes.sh
   ```
   Ele derruba os projetos `teste-*` com volumes, redes e imagens, apaga `~/.cache/bergatrix-teste` e as imagens sem nome, e avisa se sobrou algum container com mount em `/tmp/claude-*`.
2. **Conferir que nada ficou:** `docker ps -a` não mostra nada `teste-*`.
3. **Atualizar os docs** que a mudança deixou errados, no mesmo commit.
4. **Atualizar o grafo** (onde houver graphify): `graphify update .`.
5. **Dizer o que foi e o que não foi testado.** Se um teste não rodou (máquina sem Docker, por exemplo), isso aparece no resumo, junto com o que falta aplicar no servidor.

## Aplicar no servidor

Depois do push, no servidor:

```bash
cd ~/bergatrix
./00-infrastructure/atualizar.sh --ver   # o que vai mudar
./00-infrastructure/atualizar.sh         # pull e recria só o que mudou
```

Detalhes em [07-ligar-e-desligar.md](07-ligar-e-desligar.md#atualizar). Migração que precisa de passo manual (mover pasta, ordem de containers) fica escrita no documento da área, e não se roda o `atualizar.sh` antes dela.
