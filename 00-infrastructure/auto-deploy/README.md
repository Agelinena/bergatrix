# Atualização automática (auto-deploy)

Para os apps que **publicam imagem pronta** num registro (hoje só o [Tarantec](https://github.com/Agelinena/tarantec), no GHCR). A cada 5 minutos o servidor puxa a imagem do app e recria o container se ela mudou. O caminho é de dentro para fora: o GitHub não tem chave nem acesso ao servidor.

Os outros apps continuam no caminho normal: o Dependabot abre o PR do submódulo e o [`atualizar.sh`](../atualizar.sh) aplica.

| Arquivo | Papel |
|---|---|
| `auto-deploy.sh <app>` | `docker compose pull` + `up -d` em `03-apps/<app>`; limpa imagens velhas quando troca |
| `bergatrix-auto-deploy@.service` | Roda o script como o dono do repositório (grupo `docker`), não como root |
| `bergatrix-auto-deploy@.timer` | 3 min depois do boot e a cada 5 min |
| `instalar.sh <app>...` | Instala as unidades e liga o timer de cada app |

## Ligar

```bash
cd ~/bergatrix
sudo ./00-infrastructure/auto-deploy/instalar.sh tarantec
```

## Conferir e desligar

```bash
systemctl list-timers 'bergatrix-auto-deploy@*'
journalctl -u bergatrix-auto-deploy@tarantec -n 20      # "imagem nova no ar" a cada troca
sudo systemctl disable --now bergatrix-auto-deploy@tarantec.timer
```

## Requisitos do app

- Compose com `image:` e **sem** `build:` (com `build:`, o `atualizar.sh` reconstruiria a imagem do código local e ela deixaria de ser a do registro).
- Imagem pública, ou `docker login ghcr.io` feito pelo dono do repositório com um token só de `read:packages`.
- Para segurar uma versão: tag fixa no `.env` do app (no Tarantec, `TARANTEC_TAG=sha-<commit>`).
