#!/usr/bin/env python3
"""Converte os .env das stacks para o padrão de variáveis de outubro/2026.

Renomeia as variáveis que mudaram de nome, comenta as que saíram (o valor
antigo fica no arquivo, para consulta durante a migração dos dados) e
acrescenta o bloco base que falta em cada stack. Ver
docs/04-migracao-armazenamento.md.

Uso, na raiz do repositório:

  python3 scripts/migrar-env.py             # só mostra o que mudaria
  python3 scripts/migrar-env.py --aplicar   # grava (com backup de cada .env)

Os valores das raízes podem ser trocados com --appdata, --cache, --media e
--userdata. Rodar de novo não muda nada: o script é idempotente.
"""
import argparse
import difflib
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

# Variáveis renomeadas, por stack (pasta relativa à raiz do repositório)
RENOMEAR = {
    "02-security/authentik": {"PG_PASS": "POSTGRES_PASSWORD"},
    "02-security/bitwarden": {"ADMIN_TOKEN": "VAULTWARDEN_ADMIN_TOKEN"},
    "03-apps/litellm": {"LITELLM_DB_PASSWORD": "POSTGRES_PASSWORD"},
    "03-apps/n8n": {"TIMEZONE": "TZ"},
    "03-apps/openuiweb": {"WEBUI_SECRET_KEY": "OPENWEBUI_SECRET_KEY"},
    "03-apps/transcriptor": {
        "API_KEY": "TRANSCRIPTOR_API_KEY",
        "SECRET_KEY": "TRANSCRIPTOR_SECRET_KEY",
    },
}

# Variáveis que saíram (em qualquer stack)
OBSOLETAS = {
    "STORAGE_PATH",
    "VOLUMES_BASE",
    "HOMEPAGE_PATH",
    "DATA_DIR",
    "SUBDOMAIN_TRAEFIK_DASHBOARD",
    "N8N_DOMAIN",
    "USENET_DOWNLOADS_DIR",
}
OBSOLETA_RE = re.compile(r"^[A-Z0-9_]+_DATA_DIR$")
# Guardam caminhos antigos: o valor é listado no resumo
CAMINHO_RE = re.compile(r"(_PATH|_DIR|^VOLUMES_BASE)$")

# Bloco base, na ordem do padrão (docs/03-padrao-stacks.md)
BASE = ["DOMAIN", "TZ", "PUID", "PGID", "APPDATA_PATH", "CACHE_PATH", "MEDIA_PATH", "USERDATA_PATH"]

LINHA_RE = re.compile(r"^(\s*(?:export\s+)?)([A-Za-z_][A-Za-z0-9_]*)(\s*=.*)$")
# ${VAR}, ${VAR:?}, ${VAR:-padrão}; ignora $${VAR} (escapado para o container)
REF_RE = re.compile(r"(?<!\$)\$\{([A-Za-z_][A-Za-z0-9_]*)(:?[-?+])?")
MARCA = "# [antes da migração] "


def stacks(raiz):
    for compose in sorted(raiz.glob("0*/*/docker-compose.yml")):
        yield compose.parent


def variaveis_do_compose(pasta):
    """Variáveis interpoladas no compose: {nome: obrigatória?}."""
    usadas = {}
    for arquivo in pasta.glob("docker-compose*.yml"):
        for nome, modificador in REF_RE.findall(arquivo.read_text()):
            opcional = modificador.endswith(("-", "+"))
            usadas[nome] = usadas.get(nome, False) or not opcional
    return usadas


def chave(linha):
    m = LINHA_RE.match(linha)
    return m.group(2) if m else None


def valor(linha):
    return LINHA_RE.match(linha).group(3).split("=", 1)[1].strip().strip("'\"")


def migrar(pasta, rel, padroes):
    linhas = (pasta / ".env").read_text().splitlines()
    renomear = RENOMEAR.get(rel, {})
    existentes = {chave(l) for l in linhas if chave(l)}
    novas, avisos, caminhos_antigos = [], [], {}

    for linha in linhas:
        nome = chave(linha)
        if nome is None:
            novas.append(linha)
        elif nome in renomear:
            alvo = renomear[nome]
            if alvo in existentes:
                avisos.append(f"{nome} não foi renomeada: {alvo} já existe (comentei {nome})")
                novas.append(MARCA + linha)
            else:
                m = LINHA_RE.match(linha)
                novas.append(m.group(1) + alvo + m.group(3))
        elif nome in OBSOLETAS or OBSOLETA_RE.match(nome):
            if CAMINHO_RE.search(nome):
                caminhos_antigos[nome] = valor(linha)
            novas.append(MARCA + linha)
        else:
            novas.append(linha)

    usadas = variaveis_do_compose(pasta)
    presentes = {chave(l) for l in novas if chave(l)}
    faltam_base = [v for v in BASE if v in usadas and v not in presentes]
    if faltam_base:
        bloco = ["# ── Base Bergatrix (acrescentado pela migração) ──"]
        bloco += [f"{v}={padroes.get(v, '')}" for v in faltam_base]
        # Depois dos comentários iniciais do arquivo
        inicio = 0
        while (inicio < len(novas) and novas[inicio].lstrip().startswith("#")
               and not novas[inicio].startswith(MARCA)):
            inicio += 1
        novas[inicio:inicio] = bloco + [""]
        if "DOMAIN" in faltam_base and not padroes.get("DOMAIN"):
            avisos.append("DOMAIN ficou vazia: preencha à mão ou use --dominio")

    presentes = {chave(l) for l in novas if chave(l)}
    for nome, obrigatoria in sorted(usadas.items()):
        if obrigatoria and nome not in presentes:
            avisos.append(f"o compose usa {nome}, que não está no .env")

    return linhas, novas, avisos, caminhos_antigos


def mascarar(linha):
    """Esconde valores na saída, menos os que não são segredo (caminhos, domínios, base)."""
    corpo = linha[len(MARCA):] if linha.startswith(MARCA) else linha
    nome = chave(corpo)
    if nome is None or nome in BASE or nome == "TIMEZONE" or CAMINHO_RE.search(nome) or "DOMAIN" in nome:
        return linha
    m = LINHA_RE.match(corpo)
    oculto = m.group(1) + nome + "=****" if valor(corpo) else corpo
    return (MARCA if linha.startswith(MARCA) else "") + oculto


def validar(pasta):
    try:
        r = subprocess.run(
            ["docker", "compose", "config", "--quiet"],
            cwd=pasta, capture_output=True, text=True, timeout=60,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as erro:
        return f"não validado ({erro})"
    return "ok" if r.returncode == 0 else (r.stderr.strip().splitlines() or ["erro"])[-1]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--aplicar", action="store_true", help="grava as mudanças (sem isso, só mostra)")
    ap.add_argument("--raiz", type=Path, default=Path(__file__).resolve().parent.parent)
    ap.add_argument("--dominio", default="", help="DOMAIN para stacks que não têm (padrão: o das outras stacks)")
    ap.add_argument("--tz", default="America/Sao_Paulo")
    ap.add_argument("--puid", default="1000")
    ap.add_argument("--pgid", default="1000")
    ap.add_argument("--appdata", default="/srv/appdata")
    ap.add_argument("--cache", default="/srv/cache")
    ap.add_argument("--media", default="/mnt/nas/media")
    ap.add_argument("--userdata", default="/mnt/nas/userdata")
    args = ap.parse_args()

    raiz = args.raiz.resolve()
    pastas = list(stacks(raiz))

    dominio = args.dominio
    if not dominio:
        for pasta in pastas:
            env = pasta / ".env"
            if env.exists():
                for linha in env.read_text().splitlines():
                    if chave(linha) == "DOMAIN" and valor(linha):
                        dominio = valor(linha)
                        break
            if dominio:
                break

    padroes = {
        "DOMAIN": dominio, "TZ": args.tz, "PUID": args.puid, "PGID": args.pgid,
        "APPDATA_PATH": args.appdata, "CACHE_PATH": args.cache,
        "MEDIA_PATH": args.media, "USERDATA_PATH": args.userdata,
    }
    carimbo = datetime.now().strftime("%Y%m%d-%H%M%S")
    sem_env, resumo_caminhos, mudou_algo = [], [], False

    for pasta in pastas:
        rel = pasta.relative_to(raiz).as_posix()
        if not (pasta / ".env").exists():
            sem_env.append(rel)
            continue

        antes, depois, avisos, caminhos = migrar(pasta, rel, padroes)
        for nome, v in caminhos.items():
            resumo_caminhos.append(f"  {rel}: {nome}={v}")

        if antes == depois:
            print(f"= {rel}: já está no padrão")
        else:
            mudou_algo = True
            print(f"\n~ {rel}")
            for linha in difflib.unified_diff(antes, depois, "antes", "depois", lineterm="", n=0):
                if not linha.startswith(("---", "+++", "@@")):
                    print(f"    {linha[0]}{mascarar(linha[1:])}")
            if args.aplicar:
                backup = pasta / f".env.antes-migracao-{carimbo}"
                shutil.copy2(pasta / ".env", backup)
                (pasta / ".env").write_text("\n".join(depois) + "\n")
                print(f"    gravado (backup: {backup.name})")
        for aviso in avisos:
            print(f"    ⚠ {aviso}")
        if args.aplicar:
            print(f"    docker compose config: {validar(pasta)}")

    if sem_env:
        print("\nSem .env (crie a partir do .env.example):")
        for rel in sem_env:
            print(f"  {rel}")
    if resumo_caminhos:
        print("\nCaminhos antigos (onde os dados estão hoje; use no mapa do docs/04):")
        print("\n".join(resumo_caminhos))
    if mudou_algo and not args.aplicar:
        print("\nNada foi gravado. Rode de novo com --aplicar para gravar.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
