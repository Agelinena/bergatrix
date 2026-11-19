## Rotina de toda conversa

Siga [docs/04-rotina-de-trabalho.md](docs/04-rotina-de-trabalho.md). O essencial:

- **Montando algo novo:** combine o desenho antes de codar e siga a seção [Montar algo novo](docs/04-rotina-de-trabalho.md#montar-algo-novo): funcionalidade num app, stack de terceiros ou app novo com repositório próprio. O padrão das stacks está em [docs/03-padrao-stacks.md](docs/03-padrao-stacks.md); acesso em `05`, redes em `06`, armazenamento em `02`.
- **Antes:** `git pull && git submodule update --init`. Veja em que máquina está (o PC do trabalho, Windows, não tem Docker nem Go, e o antivírus bloqueia o Python, então também não roda o graphify). Código de app com repositório próprio (submódulo em `03-apps/`) muda no repositório do app, não aqui.
- **Testes com Docker:** nunca no servidor. Projeto `teste-<app>` (`docker compose -p teste-<app>`), dados em `~/.cache/bergatrix-teste/<app>` (nunca em `/tmp/claude-*` nem nas raízes de verdade), `restart: "no"`, portas altas, segredos gerados na hora.
- **Depois:** `./00-infrastructure/limpar-testes.sh` e conferir que não sobrou nada `teste-*`. Atualize os docs que a mudança deixou errados no mesmo commit. Diga o que foi e o que não foi testado, e o que falta aplicar no servidor.
- **Commits:** só com autorização, e-mail pessoal, não o do trabalho (o mesmo dos últimos commits: `git log -3 --format=%ae`), nunca `.env` nem chaves, sem domínio/IP/e-mail reais nos repositórios públicos (`example.com`).
- Fale sempre em português.

## graphify

O grafo (`graphify-out/`, nome fixo da ferramenta) é **local de cada PC** e fica fora do git. Onde o graphify não roda (PC do trabalho: o antivírus bloqueia o Python), siga sem ele e leia os arquivos direto.

- Num PC com graphify, uma vez: `graphify update .` (cria o grafo) e `graphify hook install` (reconstrói sozinho a cada commit). Com o hook, não é preciso atualizar à mão depois de mudar código.
- Quando `graphify-out/graph.json` existir, rode `graphify query "<pergunta>"` antes da primeira busca ou leitura de arquivo numa pergunta sobre o código, e repita esta regra no prompt de todo subagente que explore código. Use `graphify path "<A>" "<B>"` para relações e `graphify explain "<conceito>"` para um conceito. Leia arquivos crus só nas linhas que o grafo ou uma leitura anterior já apontou.
- `graphify-out/GRAPH_REPORT.md` só para revisão ampla de arquitetura, quando query/path/explain não bastarem.
- O código dos apps está nos submódulos (`03-apps/<app>`), cada um com repositório próprio: para eles, o grafo do Bergatrix ajuda pouco; o grafo de cada app se gera no repositório dele.
