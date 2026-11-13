# Bergakup

Backup da Bergatrix com restic e Backblaze B2. Uma interface web define **o que** entra no backup, **onde** fica e **quando**
roda. Um agente no host executa: dumps, backup, retenção, restauração e e-mails de falha.

```
┌─ Docker: 00-infrastructure/bergakup ─────────────┐
│  app (React + FastAPI) ── db (Postgres)          │  configuração, histórico, snapshots
│  bergakup.${DOMAIN}: lan-only + OIDC (Authentik) │  não executa nenhum backup
└───────────────▲──────────────────────────────────┘
                │ 127.0.0.1:8087 — o agente busca o plano e os comandos
                │ e manda os resultados (ele não abre porta)
┌───────────────┴──────────────────────────────────┐
│  bergakup-agent (Go, systemd, root)              │  restic · pg_dump · sqlite · docker
│  /etc/bergakup      identidade e chaves          │  segue rodando com a web desligada
│  /var/lib/bergakup  plano aplicado, fila         │
└──────────────────────────────────────────────────┘
```

## Os três conjuntos

Criados quando o agente se registra. Dá para editar e acrescentar outros na interface.

| Conjunto | O que é | Pastas | Consistência |
|---|---|---|---|
| `userdata` | NAS: fotos (Immich) e arquivos (Nextcloud) | `/mnt/nas/userdata` (sem miniaturas e vídeos convertidos) | só copia |
| `docker` | Repositório, composes, `.env`, identidade do agente | `~/bergatrix`, `/etc/bergakup`, `/var/lib/bergakup` | só copia |
| `servidor` | HD do servidor: configs e bancos | `/srv/appdata` (sem `*/postgres`, `*/redis`) + dumps | dumps + política de cada stack |

Cada conjunto vira um repositório restic em cada destino. Sugestão:

| Destino | Repositórios | Object Lock |
|---|---|---|
| B2 `bergatrix-sistema` | `docker`, `servidor` | 30 dias (pouco volume, janela longa para o que é crítico) |
| B2 `bergatrix-userdata` | `userdata` | 7 dias (350 GB: é o que pesa no custo) |
| NAS (pasta ou rest-server) | os três | — (histórico maior, restauração rápida) |

## Como cada coisa funciona

**Incremental sempre.** Todo dia sai um snapshot completo, mas o restic só envia os blocos que mudaram. O custo vem do volume
que muda, não de quantos snapshots ficam. Padrão no B2: 3 diários e 4 semanais.

**Bancos.** Antes do backup do `servidor`, o agente faz o dump de todo container com a label:

```yaml
labels:
  - "bergatrix.backup.dump=postgres"          # pg_dump -Fc, com o banco rodando
  # ou
  - "bergatrix.backup.dump=sqlite"
  - "bergatrix.backup.sqlite=/data/db.sqlite3"  # caminho dentro do container
```

Os dumps vão para `${APPDATA_PATH}/bergakup/dumps/<stack>/`, com um `manifest.json`. As pastas vivas dos bancos ficam fora
da cópia. A tela *Stacks e bancos* avisa sobre um container que parece banco e não tem a label.

**Stacks durante o backup.** Cada stack tem uma política: copiar rodando (padrão), parar, pausar ou ficar fora. O padrão é parar
o `jellyfin` e o `homeassistant` (SQLite em uso constante). A ordem de parar e subir segue o `stacks.txt`.
O modo *backup frio* para tudo. Com LVM no `/srv`, a parada vai cair para segundos (planejado).

**Proteções.**
- **Origem vazia ou ausente** (NAS desmontado): o backup falha, em vez de gerar um snapshot vazio.
- **Anomalia** (mais de 30% dos arquivos mudou ou sumiu): a retenção fica suspensa até você liberar na interface, para os
  snapshots bons não saírem da janela.
- **Object Lock:** o agente usa a API S3 do B2. Um "apagar" vira marcador de ocultação, e a versão travada fica até o lock vencer.
  A chave do servidor não tem `bypassGovernance`.
- **Alertas:** o e-mail sai do próprio agente. A interface avisa sobre agente sem sinal de vida e tarefa atrasada. O ping
  externo opcional (Healthchecks) cobre até o agente morto.

**Segredos.** As senhas dos repositórios, as chaves do B2 e a senha do SMTP são digitadas na interface e cifradas **no
navegador** com a chave pública do agente (sealed box do libsodium). O banco guarda só o texto cifrado, e só o agente abre.
A interface nunca mostra um segredo de volta.

Cada repositório tem duas senhas: a **operacional**, guardada cifrada para o agente, e a de **recuperação**, gerada no
navegador quando o repositório é criado e mostrada uma vez só. Ela vai para o kit impresso.

## Instalação

### 1. Authentik

Crie um provider OAuth2/OpenID (cliente confidencial) e uma aplicação `bergakup`:
- Redirect URI: `https://bergakup.example.com/auth/callback`
- Chave de assinatura RS256; escopos `openid profile email`
- Grupo `bergakup_admins` com quem pode entrar (o claim `groups` precisa ir no id_token)

### 2. DNS e stack

`bergakup.example.com` só no DNS **interno**, apontando para o Traefik. Não crie registro público. Se houver um curinga
público, o `lan-only` barra o acesso de fora mesmo assim.

```bash
cd ~/bergatrix/00-infrastructure/bergakup
cp .env.example .env        # POSTGRES_PASSWORD e dados do OIDC
sudo install -d -o 1000 -g 1000 /srv/appdata/bergakup/postgres
sudo install -d -m 0700 /srv/appdata/bergakup/dumps
docker compose up -d --build
```

### 3. Agente (no host)

```bash
cd ~/bergatrix/00-infrastructure/bergakup/agent
./build.sh                  # compila num container Go e gera o go.sum (commite o go.sum)
sudo ./install.sh           # restic 0.17.3 (conferido pelo SHA256SUMS) + agente + serviço
```

Na interface: *Agente e alertas* → *Gerar código de instalação*. Depois:

```bash
sudo bergakup-agent enroll --code bkc_... --name servidor --repo-root ~/bergatrix
sudo systemctl enable --now bergakup-agent
journalctl -u bergakup-agent -f
```

### 4. Configuração inicial (na interface)

1. **Agente e alertas:** SMTP para os e-mails de falha.
2. **Destinos e chaves:** os buckets do B2. Siga o passo a passo da própria tela: Object Lock, lifecycle e uma chave só do
   bucket, sem `bypassGovernance`. Comece com um bucket de teste em modo **Governance**.
3. **Repositórios:** conjunto × destino → *Senha* → *Criar*. Anote a senha de recuperação.
4. **Conjuntos e tarefas:** confira as pastas e crie a tarefa de cada repositório (agenda e retenção).
5. **Stacks e bancos:** confira os dumps e as políticas.
6. **Kit de recuperação:** imprima, escreva as senhas de recuperação à mão e guarde fora de casa.
7. Rode cada tarefa uma vez (*Rodar agora*). A primeira do `userdata` envia os 350 GB e leva horas.

## Recuperação de desastre

Não depende da interface: está no **Kit de recuperação** e no `sudo bergakup-agent recover`. A ordem é `docker` (devolve o
repositório, os `.env` e a identidade do agente), depois `servidor`, `subir-tudo.sh` + importar os dumps e, por último,
`userdata`.

Restaurar o `/etc/bergakup` traz de volta a mesma chave do agente, e os segredos guardados na web voltam a abrir. Por isso quem
tem a senha de um repositório `docker` tem, na prática, todos os segredos: guarde a senha de recuperação como guardaria a
Master Key do B2.

## Restauração no dia a dia

Em *Restaurar*: escolha o repositório e o snapshot, navegue, marque pastas ou arquivos e restaure no lugar original
(parando as stacks afetadas) ou numa pasta ao lado. Para bancos: restaure a pasta de dumps e use *Importar dumps*, que
também funciona para o próprio Bergakup.

## Ainda não testado / limitações conhecidas

- **Nada disto rodou ainda num servidor de verdade.** O agente e a interface foram escritos sem Go, Node ou Docker na máquina
  de desenvolvimento, então a primeira compilação (`build.sh` e o `docker compose build`) pode apontar erros. A API foi
  importada e as rotas testadas sem banco.
- **Object Lock + restic:** teste num bucket em Governance antes do Compliance. Confira se o upload, o `forget` e o `prune`
  funcionam com o lock e se o espaço é liberado depois do prazo.
- `requirements.txt` sem hashes e sem `package-lock.json` (o Transcriptor usa hashes). Gere os dois na primeira build.
- Um agente por instalação na interface (o modelo de dados já aceita vários; um agente na VM do OMV, lendo o userdata direto
  do disco, é o próximo passo natural).
- Snapshot LVM do `/srv` (parada de segundos): planejado, ainda não implementado.
- Restaurar o bucket "como estava no dia X" depois de um ataque ainda é manual (versões no painel do B2 ou `rclone --b2-versions`).
