#!/usr/bin/env python3
"""Reorganiza o HD de dados do layout antigo (docker_volumes) para o novo.

Antes: tudo em <hd>/docker_volumes/<app> (o antigo STORAGE_PATH).
Depois: <hd>/appdata, <hd>/cache e a mídia em --media (provisoriamente no
próprio HD, até o NFS do NAS estar pronto). Ver docs/04-migracao-armazenamento.md.

Só move (mv, instantâneo no mesmo disco): nada é apagado. O que não está no
mapa vai para <hd>/_legado, para decidir depois.

Uso, com o HD montado em /srv e TODOS os containers parados:

  sudo python3 scripts/migrar-dados.py             # só mostra o que faria
  sudo python3 scripts/migrar-dados.py --aplicar   # move
"""
import argparse
import os
import shutil
import sys
from pathlib import Path

# (origem relativa a docker_volumes, raiz de destino, destino relativo à raiz)
# A ordem importa: subpastas que mudam de raiz saem antes da pasta-mãe.
MAPA = [
    ("cloudbeaver", "appdata", "cloudbeaver/workspace"),
    ("traefik/logs", "appdata", "traefik/logs"),
    ("authentik/database", "appdata", "authentik/postgres"),
    ("authentik/redis", "appdata", "authentik/redis"),
    ("authentik/media", "appdata", "authentik/media"),
    ("authentik/custom-templates", "appdata", "authentik/templates"),
    ("authentik/certs", "appdata", "authentik/certs"),
    ("vaultwarden", "appdata", "bitwarden/vaultwarden"),
    ("crowdsec/config", "appdata", "crowdsec/config"),
    ("crowdsec/data", "appdata", "crowdsec/data"),
    ("bergastream/db", "appdata", "bergastream/postgres"),
    ("bergastream/redis", "appdata", "bergastream/redis"),
    ("bergastream/deemix/config", "appdata", "bergastream/deemix"),
    ("bergastream/lidarr/config", "appdata", "bergastream/lidarr"),
    ("bergastream/youtube", "appdata", "bergastream/youtube"),
    ("bergastream/pydeps", "cache", "bergastream/pydeps"),
    ("bergastream/music", "media", "musica/bergastream"),
    ("bergastream/deemix/downloads", "media", "musica/bergastream/deemix_dl"),
    ("bergastream/lidarr/music", "media", "musica/lidarr"),
    ("homeassistant/config", "appdata", "homeassistant/config"),
    *[(f"jellyflix/config/{s}", "appdata", f"jellyfin/{s}") for s in (
        "jellyfin", "catalogo", "qbittorrent", "sonarr", "radarr",
        "prowlarr", "bazarr", "sabnzbd", "recyclarr")],
    ("jellyflix/config/legendarr/jobs", "appdata", "jellyfin/legendarr/jobs"),
    ("jellyflix/config/legendarr/stats", "appdata", "jellyfin/legendarr/stats"),
    ("jellyflix/incomplete", "cache", "jellyfin/incomplete"),
    ("jellyflix/filmes", "media", "filmes"),
    ("jellyflix/series", "media", "series"),
    ("jellyflix/downloads", "media", "downloads"),
    ("litellm", "appdata", "litellm/postgres"),
    ("n8n", "appdata", "n8n/data"),
    ("openwebui", "appdata", "openuiweb/open-webui"),
    ("ollama", "cache", "openuiweb/ollama"),
    ("transcriptor/models", "cache", "transcriptor/models"),
    ("transcriptor", "appdata", "transcriptor/data"),
    ("homepage/config", "appdata", "homepage/config"),
    ("wazuh", "appdata", "wazuh"),
]


def tamanho(p, excluir=frozenset()):
    total = 0
    for raiz, pastas, arquivos in os.walk(p):
        pastas[:] = [d for d in pastas if os.path.join(raiz, d) not in excluir]
        for a in arquivos:
            try:
                total += os.lstat(os.path.join(raiz, a)).st_size
            except OSError:
                pass
    return total


def legivel(n):
    for unidade in ("B", "K", "M", "G", "T"):
        if n < 1024:
            return f"{n:.0f}{unidade}"
        n /= 1024
    return f"{n:.1f}P"


def vazio(p):
    return p.is_dir() and not any(p.iterdir())


def mover(origem, destino, aplicar, dispositivo):
    """Move origem → destino. Devolve (ok, mensagem)."""
    if not origem.exists():
        return True, "não existe (ok se a stack não usava)"
    if origem.stat().st_dev != dispositivo:
        return False, "está em outro disco: use rsync"
    if destino.exists() and not vazio(destino):
        return False, f"destino já existe e não está vazio: {destino}"
    msg = f"→ {destino}  ({legivel(tamanho(origem))})"
    if aplicar:
        destino.parent.mkdir(parents=True, exist_ok=True)
        if destino.exists():
            destino.rmdir()  # pasta vazia (ex.: ponto de montagem antigo deemix_dl)
        os.rename(origem, destino)
    return True, msg


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--aplicar", action="store_true", help="move de verdade (sem isso, só mostra)")
    ap.add_argument("--hd", type=Path, default=Path("/srv"), help="onde o HD de dados está montado")
    ap.add_argument("--appdata", type=Path, default=None, help="padrão: <hd>/appdata")
    ap.add_argument("--cache", type=Path, default=None, help="padrão: <hd>/cache")
    ap.add_argument("--media", type=Path, default=None, help="padrão: <hd>/media (provisório até o NAS)")
    ap.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    args = ap.parse_args()

    hd = args.hd
    origem_base = hd / "docker_volumes"
    raizes = {
        "appdata": args.appdata or hd / "appdata",
        "cache": args.cache or hd / "cache",
        "media": args.media or hd / "media",
    }
    legado = hd / "_legado"

    if not origem_base.is_dir():
        if raizes["appdata"].is_dir():
            print(f"Nada a fazer: {origem_base} não existe e {raizes['appdata']} já existe (já migrado).")
            return 0
        print(f"Não achei {origem_base}. O HD está montado em {hd}?")
        return 1
    if args.aplicar and os.geteuid() != 0:
        print("Rode com sudo: as pastas dos containers têm donos diferentes.")
        return 1
    dispositivo = hd.stat().st_dev

    print(f"Origem: {origem_base}")
    for nome, caminho in raizes.items():
        print(f"{nome:>8}: {caminho}")
    print()

    problemas = 0
    for rel, raiz, destino_rel in MAPA:
        ok, msg = mover(origem_base / rel, raizes[raiz] / destino_rel, args.aplicar, dispositivo)
        marca = "✓" if ok else "✗"
        problemas += not ok
        print(f"{marca} docker_volumes/{rel} {msg}")
        if rel == "ollama" and (origem_base / rel).is_dir() and not args.aplicar:
            conteudo = ", ".join(sorted(p.name for p in (origem_base / rel).iterdir()))
            print(f"    conteúdo: {conteudo}  (vai para o cache, sem backup: confira se é só modelo)")

    # acme.json ficava dentro do repositório: copia (o original fica até você conferir)
    acme = args.repo / "01-network/traefik/config/acme.json"
    acme_destino = raizes["appdata"] / "traefik/acme/acme.json"
    if acme.is_file():
        if acme_destino.exists():
            print(f"✗ acme.json: destino já existe: {acme_destino}")
            problemas += 1
        else:
            print(f"✓ {acme} → {acme_destino}  (cópia, chmod 600)")
            if args.aplicar:
                acme_destino.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(acme, acme_destino)
                os.chmod(acme_destino, 0o600)
    else:
        print(f"- acme.json não encontrado em {acme}: o Traefik pede um certificado novo")

    # Tudo que sobrou (stacks antigas, pastas vazias, conteúdo fora do mapa) → _legado
    print()
    sobras = [origem_base] + [
        p for p in sorted(hd.iterdir())
        if p.name not in {"docker_volumes", "appdata", "cache", "media", "_legado", "lost+found"}
        and p != args.repo and p not in raizes.values()
    ]
    for p in sobras:
        destino = legado / p.name
        if destino.exists():
            print(f"✗ {p} → {destino}: destino já existe")
            problemas += 1
            continue
        # Na simulação, desconta o que o mapa ainda vai mover
        mapeadas = frozenset(str(origem_base / rel) for rel, _, _ in MAPA)
        restante = legivel(tamanho(p, mapeadas)) if p.is_dir() else "arquivo"
        print(f"→ sobra {p} → {destino}  ({restante} fora do mapa)")
        if args.aplicar:
            legado.mkdir(exist_ok=True)
            os.rename(p, destino)

    print()
    if problemas:
        print(f"{problemas} item(ns) com ✗ precisam de atenção.")
    if not args.aplicar:
        print("Nada foi movido. Rode de novo com --aplicar (e sudo) para mover.")
    else:
        print(f"Pronto. Confira {legado} antes de apagar qualquer coisa dali.")
    return 1 if problemas else 0


if __name__ == "__main__":
    sys.exit(main())
