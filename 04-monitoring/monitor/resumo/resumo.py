"""Resumo diário dos alertas do Grafana, por e-mail.

O Grafana manda todo alerta (crítico ou aviso) para POST /alerta (contact point
"Resumo diário", tipo webhook). Este serviço guarda o que aconteceu e, uma vez
por dia (RESUMO_HORA, padrão 07:00), manda um e-mail com:
  - o que ainda está ativo;
  - o que aconteceu e já resolveu desde o último resumo.
Os críticos também chegam na hora pelo contact point "E-mail"; aqui entram só
para o resumo ficar completo.

Só biblioteca padrão. Estado em /dados/estado.json.

  POST /alerta        webhook do Grafana
  POST /enviar-agora  manda o resumo agora (teste)
  GET  /saude         200 se está no ar
"""
from __future__ import annotations

import json
import os
import re
import smtplib
import threading
import time
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from email.utils import formataddr
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ARQUIVO = os.environ.get("RESUMO_ESTADO", "/dados/estado.json")
HORA = os.environ.get("RESUMO_HORA", "07:00")
ENVIAR_VAZIO = os.environ.get("RESUMO_ENVIAR_VAZIO", "false").lower() in ("1", "true", "sim")
GRAFANA_URL = os.environ.get("GRAFANA_URL", "")

trava = threading.Lock()


def log(msg: str) -> None:
    print(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} {msg}", flush=True)


# ── Datas ────────────────────────────────────────────────────────

def agora() -> datetime:
    return datetime.now().astimezone()


def ler_data(texto: str | None) -> datetime | None:
    """Datas do Grafana (RFC 3339). "0001-01-01…" quer dizer "sem fim"."""
    if not texto or texto.startswith("0001-"):
        return None
    t = texto.replace("Z", "+00:00")
    # Python aceita até 6 casas de fração; o Grafana pode mandar 9
    t = re.sub(r"\.(\d{6})\d+", r".\1", t)
    try:
        d = datetime.fromisoformat(t)
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return d.astimezone()


def fmt(d: datetime) -> str:
    return d.astimezone().strftime("%d/%m %H:%M")


def duracao(seg: float) -> str:
    seg = int(seg)
    if seg < 60:
        return f"{seg} s"
    if seg < 3600:
        return f"{seg // 60} min"
    h, m = divmod(seg // 60, 60)
    return f"{h} h {m:02d} min" if h < 24 else f"{h // 24} d {h % 24} h"


# ── Estado ───────────────────────────────────────────────────────
# {"ultimo_resumo": iso, "alertas": {fingerprint: {titulo, resumo, gravidade,
#   ocorrencias: [{inicio: iso, fim: iso|null}]}}}

def carregar() -> dict:
    try:
        with open(ARQUIVO, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {"ultimo_resumo": None, "alertas": {}}
    except json.JSONDecodeError:
        log("estado.json corrompido; começando do zero")
        return {"ultimo_resumo": None, "alertas": {}}


def salvar(estado: dict) -> None:
    tmp = ARQUIVO + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(estado, f, ensure_ascii=False, indent=1)
    os.replace(tmp, ARQUIVO)


def registrar(payload: dict) -> int:
    """Guarda os alertas de um webhook. Devolve quantos vieram."""
    alertas = payload.get("alerts") or []
    with trava:
        estado = carregar()
        for a in alertas:
            fp = a.get("fingerprint") or json.dumps(a.get("labels", {}), sort_keys=True)
            labels = a.get("labels") or {}
            anot = a.get("annotations") or {}
            inicio = ler_data(a.get("startsAt")) or agora()
            fim = ler_data(a.get("endsAt")) if a.get("status") == "resolved" else None

            item = estado["alertas"].setdefault(fp, {"ocorrencias": []})
            item["titulo"] = labels.get("alertname", "Alerta")
            item["gravidade"] = labels.get("gravidade", "aviso")
            if anot.get("summary"):
                item["resumo"] = anot["summary"]

            ocs = item["ocorrencias"]
            atual = next((o for o in ocs if o["inicio"] == inicio.isoformat()), None)
            if atual is None:
                atual = {"inicio": inicio.isoformat(), "fim": None}
                ocs.append(atual)
            if fim is not None:
                atual["fim"] = fim.isoformat()
        salvar(estado)
    return len(alertas)


# ── Resumo ───────────────────────────────────────────────────────

def montar(estado: dict, desde: datetime, ate: datetime) -> tuple[str, str, int] | None:
    ativos: list[tuple] = []
    resolvidos: list[tuple] = []

    for item in estado["alertas"].values():
        titulo = item.get("titulo", "Alerta")
        resumo = item.get("resumo", "")
        critico = item.get("gravidade") == "critico"
        ocs = [(ler_data(o["inicio"]), ler_data(o["fim"])) for o in item["ocorrencias"]]

        abertas = [i for i, f in ocs if f is None]
        fechadas = [(i, f) for i, f in ocs if f is not None and f >= desde]
        if abertas:
            ativos.append((not critico, titulo, resumo, min(abertas), critico))
        if fechadas:
            total = sum((f - i).total_seconds() for i, f in fechadas)
            resolvidos.append((not critico, titulo, resumo, len(fechadas), total, max(f for _, f in fechadas), critico))

    if not ativos and not resolvidos and not ENVIAR_VAZIO:
        return None

    ativos.sort()
    resolvidos.sort()
    marca = lambda c: "  [crítico, já avisado na hora]" if c else ""

    linhas = [f"Alertas de {fmt(desde)} a {fmt(ate)}.", ""]
    if ativos:
        linhas.append(f"AINDA ATIVOS ({len(ativos)})")
        for _, titulo, resumo, inicio, c in ativos:
            linhas.append(f"  ● {titulo}{marca(c)}")
            if resumo:
                linhas.append(f"    {resumo}")
            linhas.append(f"    desde {fmt(inicio)} ({duracao((ate - inicio).total_seconds())})")
        linhas.append("")
    if resolvidos:
        linhas.append(f"ACONTECERAM E JÁ RESOLVERAM ({len(resolvidos)})")
        for _, titulo, resumo, vezes, total, ultimo, c in resolvidos:
            vez = "1 vez" if vezes == 1 else f"{vezes} vezes"
            linhas.append(f"  ✓ {titulo}{marca(c)}")
            if resumo:
                linhas.append(f"    {resumo}")
            linhas.append(f"    {vez}, {duracao(total)} no total, a última até {fmt(ultimo)}")
        linhas.append("")
    if not ativos and not resolvidos:
        linhas += ["Nada aconteceu no período.", ""]
    if GRAFANA_URL:
        linhas.append(f"Painéis: {GRAFANA_URL}")

    assunto = f"[Bergatrix] Resumo de {desde.strftime('%d/%m')}: "
    partes = []
    if ativos:
        partes.append(f"{len(ativos)} ativo(s)")
    if resolvidos:
        partes.append(f"{len(resolvidos)} resolvido(s)")
    assunto += ", ".join(partes) if partes else "tudo certo"
    return assunto, "\n".join(linhas), len(ativos) + len(resolvidos)


def limpar(estado: dict, ate: datetime) -> None:
    """Tira o que já foi resumido e resolvido."""
    for fp in list(estado["alertas"]):
        item = estado["alertas"][fp]
        item["ocorrencias"] = [
            o for o in item["ocorrencias"] if o["fim"] is None or ler_data(o["fim"]) > ate
        ]
        if not item["ocorrencias"]:
            del estado["alertas"][fp]


def enviar_email(assunto: str, corpo: str) -> None:
    host = os.environ["SMTP_HOST"]
    porta = int(os.environ.get("SMTP_PORT", "587"))
    usuario = os.environ.get("SMTP_USERNAME", "")
    senha = os.environ.get("SMTP_PASSWORD", "")
    remetente = os.environ["SMTP_FROM_ADDRESS"]
    politica = os.environ.get("SMTP_STARTTLS_POLICY", "MandatoryStartTLS")
    destinos = [d.strip() for d in re.split(r"[;,]", os.environ["ALERTAS_EMAIL"]) if d.strip()]

    msg = EmailMessage()
    msg["Subject"] = assunto
    msg["From"] = formataddr(("Bergatrix Monitor", remetente))
    msg["To"] = ", ".join(destinos)
    msg.set_content(corpo)

    if porta == 465:
        smtp: smtplib.SMTP = smtplib.SMTP_SSL(host, porta, timeout=30)
    else:
        smtp = smtplib.SMTP(host, porta, timeout=30)
        if politica != "NoStartTLS":
            smtp.starttls()
    with smtp:
        if usuario:
            smtp.login(usuario, senha)
        smtp.send_message(msg)


def resumir() -> str:
    with trava:
        estado = carregar()
        ate = agora()
        desde = ler_data(estado.get("ultimo_resumo")) or ate - timedelta(days=1)
        r = montar(estado, desde, ate)
        if r is None:
            log("resumo: nada no período, e-mail não enviado")
        else:
            assunto, corpo, n = r
            enviar_email(assunto, corpo)
            log(f"resumo enviado: {assunto}")
        estado["ultimo_resumo"] = ate.isoformat()
        limpar(estado, ate)
        salvar(estado)
        return "enviado" if r else "nada a enviar"


# ── Agenda ───────────────────────────────────────────────────────

def horario_de_hoje() -> datetime:
    h, m = (int(x) for x in HORA.split(":"))
    return agora().replace(hour=h, minute=m, second=0, microsecond=0)


def agenda() -> None:
    while True:
        alvo = horario_de_hoje()
        with trava:
            ultimo = ler_data(carregar().get("ultimo_resumo"))
        # Já passou da hora de hoje e o resumo de hoje não saiu (ex.: o
        # container estava parado às 07:00): manda agora.
        if agora() >= alvo and (ultimo is None or ultimo < alvo):
            try:
                resumir()
            except Exception as e:  # noqa: BLE001 - não pode derrubar a agenda
                log(f"ERRO ao enviar o resumo: {e!r}; tento de novo em 10 min")
                time.sleep(600)
                continue
        time.sleep(60)


# ── HTTP ─────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    def _responder(self, codigo: int, texto: str) -> None:
        dados = texto.encode()
        self.send_response(codigo)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(dados)))
        self.end_headers()
        self.wfile.write(dados)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/saude":
            self._responder(200, "ok")
        else:
            self._responder(404, "não encontrado")

    def do_POST(self) -> None:  # noqa: N802
        tamanho = int(self.headers.get("Content-Length") or 0)
        corpo = self.rfile.read(tamanho) if tamanho else b""
        try:
            if self.path == "/alerta":
                n = registrar(json.loads(corpo or b"{}"))
                self._responder(200, f"{n} alerta(s) registrados")
            elif self.path == "/enviar-agora":
                self._responder(200, resumir())
            else:
                self._responder(404, "não encontrado")
        except Exception as e:  # noqa: BLE001
            log(f"ERRO em {self.path}: {e!r}")
            self._responder(500, f"erro: {e}")

    def log_message(self, *_args) -> None:  # sem log por requisição
        pass


def main() -> None:
    for var in ("SMTP_HOST", "SMTP_FROM_ADDRESS", "ALERTAS_EMAIL"):
        if not os.environ.get(var):
            log(f"AVISO: {var} vazio; o resumo não vai conseguir mandar e-mail")
    with trava:
        if not os.path.exists(ARQUIVO):
            salvar({"ultimo_resumo": agora().isoformat(), "alertas": {}})
    threading.Thread(target=agenda, daemon=True).start()
    log(f"resumo diário às {HORA}; escutando na porta 8080")
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()


if __name__ == "__main__":
    main()
