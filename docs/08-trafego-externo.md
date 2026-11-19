# Tráfego de fora

Como uma conexão da internet chega ao Traefik. O servidor de casa não fica exposto: uma VPS em São Paulo recebe o tráfego, filtra e o repassa por um túnel WireGuard. A VPS não tem certificados nem lê HTTP; o TLS termina no Traefik, em casa.

```
Cliente ─▶ VPS (nftables: só IPs do Brasil ─▶ HAProxy em modo TCP, PROXY protocol v2)
        ─▶ túnel WireGuard ─▶ Traefik :443 (lê o PROXY protocol, termina o TLS) ─▶ CrowdSec ─▶ app
```

## VPS (borda)

| Peça | O que faz |
|---|---|
| **nftables (GeoIP)** | Descarta em silêncio, nas portas 80 e 443, tudo que não vem de IP do Brasil. Sem resposta: para quem está fora, o servidor parece não existir. |
| **tc + CAKE** | Limita a interface pública (~240 Mbit) para que um upload grande (Immich, Nextcloud) não aumente a latência do túnel. |
| **HAProxy** | Escuta 80 e 443 em modo `tcp` e repassa ao servidor pelo túnel com `send-proxy-v2`, que leva junto o IP real do cliente. |

Portas abertas na VPS: 80, 443, SSH (restrito) e a do WireGuard.

## Túnel

- WireGuard ponto a ponto entre a VPS e o servidor. A VPS é `10.100.0.1` dentro do túnel.
- O túnel é roteado até o IP local do servidor Docker.

## Servidor (Traefik e CrowdSec)

- Os entrypoints do Traefik aceitam PROXY protocol **só** de `10.100.0.1/32` ([`traefik.yml`](../01-network/traefik/config/traefik.yml)). Ninguém da rede local ou de um container consegue forjar o IP de origem.
- Com o IP real, o CrowdSec bane o atacante, e não o túnel.
- Da rede de casa, o tráfego vai direto ao Traefik, sem passar pela VPS.

## Camadas de proteção

| Camada | Onde | O quê |
|---|---|---|
| 3/4 | VPS | Bloqueio por país, sem resposta, e só as portas necessárias |
| Trânsito | Túnel | WireGuard entre a VPS e a casa |
| 7 | Servidor | CrowdSec sobre os logs do Traefik; Authentik na frente dos apps ([05-acesso.md](05-acesso.md)) |
| Confiança | Traefik | PROXY protocol aceito só do IP da VPS no túnel |

A configuração da VPS (nftables, CAKE, HAProxy, WireGuard) fica nela, fora deste repositório.
