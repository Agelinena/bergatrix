# networks — Runbook de bootstrap que cria as duas redes Docker externas compartilhadas (bergatrix-proxy e bergatrix-backend) das quais todo o homelab depende

> **Categoria:** infrastructure | **Caminho:** `00-infrastructure/networks` | **Status:** stable

## 🎯 Finalidade
Esta "stack" nao roda nenhum servico — ela e a fundacao de rede do homelab Bergatrix. O diretorio contem um unico arquivo, `networks.md`, com dois comandos:

```
docker network create bergatrix-proxy
docker network create bergatrix-backend
```

O proposito e centralizar a criacao das redes Docker bridge compartilhadas. Essas redes precisam existir **antes** de qualquer outra stack subir, porque praticamente todos os `docker-compose.yml` do repositorio declaram `bergatrix-proxy` como rede `external: true`. Se a rede nao existir, o `docker compose up` falha. Ao centralizar a criacao aqui, evita-se que cada stack tente criar a rede e garante-se um plano de rede comum para todo o homelab.

- **bergatrix-proxy**: rede de borda compartilhada por onde o Traefik faz o roteamento reverso. Cada servico exposto publicamente se conecta a ela e define a label `traefik.docker.network=bergatrix-proxy`.
- **bergatrix-backend**: prevista como rede interna para comunicacao service-to-service sem exposicao ao Traefik, mas atualmente **orfa** (nao referenciada por nenhuma stack).

## 🧱 Stack tecnologica
- Docker Engine (daemon local do host)
- Docker networking — driver `bridge` (padrao, single-node)
- Shell / Docker CLI

Nao ha linguagem de programacao, framework, banco de dados ou imagem de container envolvidos. E configuracao pura de infraestrutura.

## 📦 Servicos / Containers
Nao se aplica. Esta stack nao define nenhum servico ou container — nao ha `docker-compose.yml` nem `Dockerfile`. Apenas dois comandos `docker network create` executados uma vez no host.

## 🌐 Dominios / Roteamento
Interno apenas (infraestrutura de rede). Esta stack nao expoe hostnames nem define regras Traefik. Porem, a rede `bergatrix-proxy` criada aqui e o substrato sobre o qual TODO o roteamento Traefik acontece: e nela que o Traefik (01-network/traefik) descobre containers e a label `traefik.docker.network=bergatrix-proxy` direciona o trafego.

## 📐 Regras de negocio
- As redes `bergatrix-proxy` e `bergatrix-backend` devem ser criadas manualmente **uma unica vez**, antes de subir qualquer outra stack, pois sao referenciadas como `external: true` pelos demais composes.
- `bergatrix-proxy` e a rede compartilhada de borda: e por ela que o Traefik roteia trafego para os containers. Servicos expostos publicamente conectam-se a ela e definem `traefik.docker.network=bergatrix-proxy`.
- Os comandos nao especificam `--driver`, portanto ambas as redes usam o driver padrao do Docker (`bridge` em host single-node). Nao ha definicao de subnet, gateway ou MTU.

## 🚨 Infraestrutura critica: DNS do servidor para o cert wildcard

> **Nao remover** a regra de NAT descrita abaixo. Sem ela, a renovacao automatica do certificado wildcard `*.daberga.com` falha em **~60 dias** e todo o ingress HTTPS do homelab para.

**Causa-raiz (resolvida).** O OPNsense fazia **hijacking transparente de todo o trafego DNS na porta 53** (redirecionamento split-horizon: qualquer query DNS da LAN era capturada e respondida pelo resolver interno, independentemente do servidor consultado). Com isso, o Traefik/lego **nao conseguia descobrir a zona `daberga.com` via consulta SOA** ao autoritativo do deSEC — a query era sequestrada, e a emissao do certificado quebrava com o erro `domainName=com` (o lego, sem achar a zona, "subia" na arvore de dominios ate sobrar apenas o TLD `com`).

**Solucao.** Uma regra **NAT → Port Forward** no OPNsense marcada como **"No RDR (NOT)"**:
- **Origem:** `192.168.10.10` (o BergaServer)
- **Porta de destino:** `53` (DNS)
- **Efeito:** isenta o DNS do servidor do redirecionamento transparente, deixando as queries sairem **direto** aos autoritativos (`ns1.desec.io` / `ns2.desec.org`) sem sequestro.

Complementos no stack do Traefik (`01-network/traefik`): `dns: 9.9.9.9 / 149.112.112.112` (Quad9) no container, resolvers ACME apontando para o autoritativo do deSEC e `LEGO_DISABLE_CNAME_SUPPORT=true`. Detalhes em [traefik.md](traefik.md).

> ⚠️ **Para renovacoes futuras:** a regra "No RDR" do OPNsense e parte **permanente** da infraestrutura — inclua-a no backup da config do OPNsense e nao a remova ao limpar regras de firewall.

## 🗄️ Modelo de dados
n/a — nao ha banco de dados nem modelo de dados. O unico "modelo" e a topologia de rede: duas redes Docker bridge nomeadas (`bergatrix-proxy` = borda/roteamento Traefik; `bergatrix-backend` = backend interno planejado, atualmente orfa).

## 🔌 Endpoints / API
n/a — nao ha API nem rotas.

## 🔗 Integracoes externas
- **Docker Engine (daemon) no host** — as redes sao recursos do daemon local, criadas via Docker CLI.

## 🧩 Dependencias internas (Bergatrix)
Esta stack nao tem dependencias de entrada — ela e a base. No sentido inverso, e pre-requisito de praticamente todo o homelab. A rede `bergatrix-proxy` e consumida como `external: true` por **16 docker-compose.yml**:

| # | Stack | # | Stack |
|---|-------|---|-------|
| 1 | 01-network/traefik | 9 | 03-apps/drop |
| 2 | 02-security/authentik | 10 | 03-apps/ghostmap |
| 3 | 02-security/bitwarden | 11 | 03-apps/litellm |
| 4 | 00-infrastructure/cloudbeaver | 12 | 03-apps/n8n |
| 5 | 03-apps/bergastream | 13 | 03-apps/rss-ig |
| 6 | 03-apps/jellyfin | 14 | 03-apps/rss |
| 7 | 03-apps/openuiweb | 15 | 03-apps/transcriptor |
| 8 | 03-apps/berga-news | 16 | 04-monitoring/wazuh |

O **Traefik** (01-network/traefik) e o consumidor central: usa `bergatrix-proxy` como rede de descoberta/roteamento, e a label `traefik.docker.network=bergatrix-proxy` e o padrao adotado pelos apps.

## 🔑 Variaveis de ambiente necessarias
Nenhuma. A stack nao usa variaveis de ambiente, arquivos `.env`, tokens ou credenciais.

## 🗂️ Estrutura de codigo
- `networks.md` — unico arquivo da stack (2 linhas). Funciona como runbook/script de provisionamento, contendo os dois comandos `docker network create`. Nao ha `docker-compose.yml`, `Dockerfile`, `.env` nem codigo-fonte.

## 🛡️ Gestao de segredos
Nenhum segredo envolvido. A stack contem apenas dois comandos de criacao de rede Docker, sem variaveis, tokens ou credenciais. Verificado: `networks.md` nao contem nenhum valor sensivel. Nenhuma exposicao detectada.

## 🚧 Notas de evolucao / pendencias
- **bergatrix-backend esta orfa**: e criada pelo runbook, mas a unica ocorrencia do termo em toda a arvore do repositorio e a propria linha de criacao em `networks.md`. As stacks que precisam de isolamento interno definem localmente uma rede `internal:` com `driver: bridge` em cada compose (confirmado em `03-apps/bergastream/docker-compose.yml`) em vez de usar a `bergatrix-backend` compartilhada. Indicio de feature planejada porem nao adotada, ou de refatoracao pendente para centralizar a rede backend.
- **Sem idempotencia**: documentada como `.md` (runbook), nao como script `.sh` nem como compose. Reexecutar os comandos com a rede ja existente retorna erro `network already exists`. Poderia evoluir para um script idempotente (ex: `docker network inspect <nome> >/dev/null 2>&1 || docker network create <nome>`).
- **Sem parametrizacao de rede**: nenhum comando define subnet, gateway, MTU ou opcoes de driver — tudo no default do Docker.

## ❓ Perguntas em aberto
- `bergatrix-backend` deveria ser adotada pelas stacks no lugar das redes `internal` locais de cada compose? Atualmente esta orfa.
- Esta stack deveria ser convertida em um script idempotente / Makefile de bootstrap, para evitar erros de re-execucao e documentar a ordem de inicializacao do homelab?
- Ha intencao de definir subnets/ranges fixos para as redes (util para regras de firewall ou DNS interno), ou o default bridge e suficiente?

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a stack evoluir._
