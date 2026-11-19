## Rotina de toda conversa

Siga [docs/04-rotina-de-trabalho.md](docs/04-rotina-de-trabalho.md). O essencial:

- **Montando algo novo:** combine o desenho antes de codar e siga a seção [Montar algo novo](docs/04-rotina-de-trabalho.md#montar-algo-novo): funcionalidade num app, stack de terceiros ou app novo com repositório próprio. O padrão das stacks está em [docs/03-padrao-stacks.md](docs/03-padrao-stacks.md); acesso em `05`, redes em `06`, armazenamento em `02`.
- **Antes:** `git pull && git submodule update --init`. Veja em que máquina está (o PC do trabalho, Windows, não tem Docker, Python, Go nem graphify). Código de app com repositório próprio (submódulo em `03-apps/`) muda no repositório do app, não aqui.
- **Testes com Docker:** nunca no servidor. Projeto `teste-<app>` (`docker compose -p teste-<app>`), dados em `~/.cache/bergatrix-teste/<app>` (nunca em `/tmp/claude-*` nem nas raízes de verdade), `restart: "no"`, portas altas, segredos gerados na hora.
- **Depois:** `./00-infrastructure/limpar-testes.sh` e conferir que não sobrou nada `teste-*`. Atualize os docs que a mudança deixou errados no mesmo commit. Diga o que foi e o que não foi testado, e o que falta aplicar no servidor.
- **Commits:** só com autorização, e-mail pessoal, não o do trabalho (o mesmo dos últimos commits: `git log -3 --format=%ae`), nunca `.env` nem chaves, sem domínio/IP/e-mail reais nos repositórios públicos (`example.com`).
- Fale sempre em português.

## graphify

Onde o graphify não estiver instalado (PC do trabalho), siga sem ele: leia os arquivos direto.

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- When graphify-out/graph.json exists, run `graphify query "<question>"` before your first grep, search or source-file read for a codebase question, and put this rule in every subagent prompt that explores code. Read raw files only for lines the graph or an earlier read already located. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
- A committed graphify-out/graph.json is rewritten whole on every build, so a large diff to it in a pull request is expected. Do not flag it as churn or suggest skipping the graph rebuild or its hooks.
