"""Textos dos e-mails de conta (assunto, corpo em texto simples)."""
from __future__ import annotations

from app.config import settings


def _hello(name: str) -> str:
    return f"Olá, {name}!"


def _app() -> str:
    return settings.public_url or "o Bergastream"


def password_changed(name: str, by_admin: bool) -> tuple[str, str]:
    who = "O administrador redefiniu" if by_admin else "Você trocou"
    return ("Sua senha do Bergastream foi trocada",
            f"{_hello(name)}\n\n{who} a senha da sua conta no Bergastream. Os aparelhos "
            "conectados precisam entrar de novo.")


def temporary_password(name: str) -> tuple[str, str]:
    return ("Sua senha do Bergastream foi redefinida",
            f"{_hello(name)}\n\nO administrador definiu uma senha temporária para a sua conta "
            "no Bergastream e vai passar ela para você. Depois de entrar, troque em "
            "Ajustes → Conta → Trocar senha. Os aparelhos conectados precisam entrar de novo.")


def reset_link(name: str, url: str, hours: int) -> tuple[str, str]:
    return ("Redefinir a senha do Bergastream",
            f"{_hello(name)}\n\nPara criar uma senha nova, abra o link abaixo (vale por "
            f"{hours} h e só uma vez):\n\n{url}\n\nSe você não pediu, ignore este e-mail: a "
            "senha atual continua valendo.")


def invite(name: str, username: str, url: str | None, hours: int) -> tuple[str, str]:
    if url:
        how = (f"Para começar, crie sua senha pelo link abaixo (vale por {hours} h):\n\n{url}"
               f"\n\nDepois é só entrar em {_app()} com o usuário \"{username}\".")
    elif settings.oidc_enabled:
        how = (f"Entre em {_app()} com \"Entrar com o Authentik\", usando a sua conta de lá "
               f"(usuário \"{username}\").")
    else:
        how = (f"Entre em {_app()} com o usuário \"{username}\"; o administrador vai passar "
               "a senha.")
    return ("Sua conta no Bergastream", f"{_hello(name)}\n\nFoi criada uma conta para você no "
            f"Bergastream, o streaming de música do servidor.\n\n{how}")


def email_changed_old(name: str, new_email: str) -> tuple[str, str]:
    return ("O e-mail da sua conta no Bergastream mudou",
            f"{_hello(name)}\n\nO e-mail da sua conta no Bergastream foi trocado para "
            f"{new_email}. Os próximos avisos vão para lá.")


def email_changed_new(name: str) -> tuple[str, str]:
    return ("Este é o novo e-mail da sua conta no Bergastream",
            f"{_hello(name)}\n\nEste endereço passou a ser o e-mail da sua conta no "
            "Bergastream. Os avisos da conta chegam aqui.")


def username_changed(name: str, old: str, new: str) -> tuple[str, str]:
    return ("Seu usuário do Bergastream mudou",
            f"{_hello(name)}\n\nSeu usuário no Bergastream passou de \"{old}\" para \"{new}\". "
            "Use o novo para entrar com senha.")


def disabled(name: str) -> tuple[str, str]:
    return ("Sua conta no Bergastream foi desativada",
            f"{_hello(name)}\n\nSua conta no Bergastream foi desativada pelo administrador. "
            "Suas playlists e seu histórico continuam guardados.")


def enabled(name: str) -> tuple[str, str]:
    return ("Sua conta no Bergastream foi reativada",
            f"{_hello(name)}\n\nSua conta no Bergastream está ativa de novo. É só entrar em "
            f"{_app()}.")


def custom(name: str, subject: str, message: str) -> tuple[str, str]:
    # Quebra de linha no assunto viraria outro cabeçalho do e-mail.
    return (" ".join(subject.split()), f"{_hello(name)}\n\n{message.strip()}")


def test(name: str) -> tuple[str, str]:
    return ("Teste de e-mail do Bergastream",
            f"{_hello(name)}\n\nSe você recebeu esta mensagem, o envio de e-mails do "
            "Bergastream está funcionando.")
