"""Envio de e-mail por SMTP (avisos de conta, convites, redefinir senha).

Configurado pelas variáveis SMTP_* do .env. Sem SMTP_HOST, `send` só
registra que não enviou: nada no app depende do e-mail chegar.

O envio usa o smtplib da biblioteca padrão numa thread (é raro e pequeno).
Nos testes, `set_transport` troca o envio por uma função que guarda as
mensagens.
"""
from __future__ import annotations

import asyncio
import html
import logging
import smtplib
import ssl
from email.message import EmailMessage
from email.utils import formataddr, make_msgid, parseaddr
from typing import Callable

from app.config import settings

logger = logging.getLogger("bergastream.mail")

Transport = Callable[[EmailMessage], None]
_transport: Transport | None = None


class MailError(Exception):
    pass


def set_transport(transport: Transport | None) -> None:
    """Troca o envio (testes). None volta ao SMTP."""
    global _transport
    _transport = transport


def enabled() -> bool:
    return _transport is not None or settings.mail_enabled


def _smtp_send(message: EmailMessage) -> None:
    security = settings.smtp_security.lower()
    context = ssl.create_default_context()
    timeout = settings.smtp_timeout_seconds
    if security == "ssl":
        server = smtplib.SMTP_SSL(settings.smtp_host, settings.smtp_port,
                                  timeout=timeout, context=context)
    else:
        server = smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=timeout)
    with server:
        if security == "starttls":
            server.starttls(context=context)
        if settings.smtp_username:
            server.login(settings.smtp_username, settings.smtp_password)
        server.send_message(message)


def build(to: str, subject: str, text: str) -> EmailMessage:
    """Mensagem em texto e HTML simples (o HTML é o mesmo texto, escapado)."""
    message = EmailMessage()
    sender = settings.smtp_from or "Bergastream <bergastream@localhost>"
    name, address = parseaddr(sender)
    message["From"] = formataddr((name or "Bergastream", address))
    message["To"] = to
    message["Subject"] = subject
    message["Message-ID"] = make_msgid(domain=(address.split("@")[-1] or None))
    body = text + _FOOTER
    message.set_content(body)
    paragraphs = "".join(
        f"<p>{_linkify(html.escape(p)).replace(chr(10), '<br>')}</p>" for p in body.split("\n\n"))
    message.add_alternative(
        f"""<!doctype html><html lang="pt-BR"><body style="font-family:system-ui,sans-serif;
color:#222;max-width:36rem;margin:0 auto;padding:1rem">{paragraphs}</body></html>""",
        subtype="html")
    return message


def _linkify(escaped: str) -> str:
    import re
    return re.sub(r"(https?://[^\s<]+)", r'<a href="\1">\1</a>', escaped)


_FOOTER = ("\n\n—\nBergastream. Se não foi você quem pediu isso, fale com o administrador "
           "do servidor.")


async def send(to: str | None, subject: str, text: str) -> bool:
    """Envia; devolve se foi. Falha de SMTP vira log (quem chama segue)."""
    if not to:
        return False
    if not enabled():
        logger.info("[e-mail] SMTP não configurado; aviso %r não enviado", subject)
        return False
    message = build(to, subject, text)
    try:
        await asyncio.to_thread(_transport or _smtp_send, message)
    except Exception as exc:
        # Sem o endereço no log (dado pessoal).
        logger.warning("[e-mail] falhou %r: %s", subject, exc)
        return False
    return True


async def send_or_raise(to: str, subject: str, text: str) -> None:
    """Para o "Testar e-mail": mostra o erro do SMTP para o admin."""
    if not enabled():
        raise MailError("SMTP não configurado (SMTP_HOST e SMTP_FROM no .env).")
    try:
        await asyncio.to_thread(_transport or _smtp_send, build(to, subject, text))
    except Exception as exc:
        raise MailError(f"O servidor de e-mail recusou: {exc}") from exc
