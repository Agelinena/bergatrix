# Ligar e desligar tudo

Dois scripts sobem e derrubam a Bergatrix inteira na ordem certa. A ordem fica num arquivo só, o [`00-infrastructure/stacks.txt`](../00-infrastructure/stacks.txt).

| Script | O que faz |
|---|---|
| [`subir-tudo.sh`](../00-infrastructure/subir-tudo.sh) | Cria as [redes](06-redes.md) e sobe cada stack, na ordem do `stacks.txt`. No fim, avisa se há containers no ar que não estão na lista. |
| [`derrubar-tudo.sh`](../00-infrastructure/derrubar-tudo.sh) | Pede confirmação e derruba as stacks na ordem inversa. Dados, imagens e redes ficam. |

```bash
cd ~/bergatrix
./00-infrastructure/subir-tudo.sh
./00-infrastructure/derrubar-tudo.sh      # pergunta antes
./00-infrastructure/derrubar-tudo.sh -y   # sem perguntar
```

## Como se comportam

- **Pode rodar o `subir-tudo.sh` de novo a qualquer momento.** Stack no ar e sem mudança fica como está. Stack com compose ou `.env` alterado é recriada.
- **Stack sem `.env` é pulada.** O script entende que ela não está configurada nesse servidor e avisa.
- **Uma stack que falha não para as outras.** No fim aparece a lista das que falharam, e o script sai com erro.
- **O `derrubar-tudo.sh` usa só o nome do projeto** (`docker compose -p <pasta> down`). Funciona mesmo sem o `.env` ou com o compose já alterado.
- **Nenhum dos dois apaga dados.** Volumes, pastas em `/srv` e no NAS, imagens e redes continuam lá.

## Stack nova, removida ou renomeada

**O `stacks.txt` precisa acompanhar o repositório.** Toda mudança de stack atualiza a lista no mesmo commit:

| Mudança | No `stacks.txt` |
|---|---|
| Stack nova | Acrescente a linha **depois** das stacks de que ela depende (Traefik, Authentik, a que fornece um serviço para ela) |
| Stack removida | Apague a linha. No servidor, derrube-a **antes** do `git pull`: `docker compose -p <pasta> down` |
| Stack renomeada | Troque a linha. No servidor, derrube com o nome antigo e suba com o novo |
| Serviço novo dentro de uma stack existente | Nada: ele sobe com a stack |

Se um container ficar fora da lista, o `subir-tudo.sh` mostra no fim: "Containers no ar fora do stacks.txt".

## A ordem

1. **Redes** (`01-network/redes`), sempre primeiro, pelo próprio script.
2. **CrowdSec e Traefik:** entrada de tráfego e bloqueio.
3. **Authentik e Vaultwarden:** login de todo o resto.
4. **Ferramentas de base** (CloudBeaver).
5. **Apps**, com quem fornece serviço antes de quem usa: o Ollama antes do Jellyfin (Legendarr), e o Jellyfin antes do bergastream (o Lidarr usa o SABnzbd e o Prowlarr).
6. **Monitoramento** (Wazuh).

A ordem garante que as dependências estejam no ar primeiro, mas um app não espera o outro ficar pronto. Se algo depende de um serviço lento para iniciar (como o Authentik), o próprio app precisa tentar de novo. É o que os apps daqui já fazem.

## Depois de reiniciar o servidor

Não é preciso rodar o script. Os containers têm `restart: unless-stopped` e voltam sozinhos quando o Docker sobe. O Docker só sobe depois de montar o HD e o NFS (`RequiresMountsFor`, em [02-armazenamento.md](02-armazenamento.md)).

O `subir-tudo.sh` serve para:
- a primeira subida;
- voltar depois de um `derrubar-tudo.sh`;
- aplicar de uma vez as mudanças de um `git pull`.
