# Documentação da Bergatrix

Ponto de partida para entender o servidor e criar ou alterar qualquer stack.

| Documento | Para quê |
|---|---|
| [01-infraestrutura.md](01-infraestrutura.md) | Máquinas, discos, caminho do tráfego, stacks e dependências entre elas |
| [02-armazenamento.md](02-armazenamento.md) | As quatro raízes de dados, o que vai em cada uma, montagem e backup |
| [03-padrao-stacks.md](03-padrao-stacks.md) | O padrão de toda stack: pastas, variáveis, volumes, redes e checklist de stack nova |
| [04-migracao-armazenamento.md](04-migracao-armazenamento.md) | Passo a passo da migração para o novo armazenamento (uso único) |
| [templates/](templates/) | `docker-compose.yml` e `.env.example` modelo |
| [legado/](legado/) | Documentação anterior, desatualizada. Fica só como consulta até ser reescrita. |

## Regras desta documentação

- **O código é a fonte da verdade.** Se um documento e um compose discordarem, vale o compose, e o documento precisa ser corrigido.
- **Repositório público:** sem domínio, IPs, e-mails ou segredos reais. Use `example.com` e `<ip-do-nas>`. Os valores reais ficam no repositório privado.
- Ao mudar uma stack, atualize o [mapa de armazenamento](02-armazenamento.md#mapa-atual-por-stack) e a [tabela de stacks](01-infraestrutura.md#stacks) no mesmo commit.
