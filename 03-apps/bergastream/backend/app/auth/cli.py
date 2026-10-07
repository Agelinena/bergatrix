"""Gerência de usuários pela linha de comando.

Uso (dentro do container da API):
    python -m app.auth.cli create-user <username> [--admin]
    python -m app.auth.cli set-password <username>
    python -m app.auth.cli list-users

A senha é pedida no terminal (ou lida da entrada padrão com --password-stdin).
"""
from __future__ import annotations

import argparse
import asyncio
import getpass
import sys

from app.auth import repository as repo
from app.auth.security import hash_password
from app.core.db import close_pool, create_pool


def _read_password(from_stdin: bool) -> str:
    if from_stdin:
        password = sys.stdin.readline().rstrip("\n")
    else:
        password = getpass.getpass("Senha: ")
        if getpass.getpass("Repita a senha: ") != password:
            sys.exit("As senhas não conferem.")
    if len(password) < 8:
        sys.exit("A senha precisa ter pelo menos 8 caracteres.")
    return password


async def _main(args: argparse.Namespace) -> None:
    pool = await create_pool()
    try:
        if args.command == "list-users":
            rows = await pool.fetch(
                "SELECT username, is_admin, password_hash IS NOT NULL AS has_password "
                "FROM users ORDER BY username"
            )
            for r in rows:
                flags = ("admin " if r["is_admin"] else "") + (
                    "" if r["has_password"] else "(sem senha)"
                )
                print(f"{r['username']} {flags}".rstrip())
            return

        existing = await repo.get_user_by_username(pool, args.username)
        password = _read_password(args.password_stdin)
        if args.command == "create-user":
            if existing:
                sys.exit(f"Usuário {args.username!r} já existe.")
            await repo.create_user(pool, args.username, hash_password(password), args.admin)
            print(f"Usuário {args.username!r} criado.")
        else:
            if not existing:
                sys.exit(f"Usuário {args.username!r} não existe.")
            await repo.set_password(pool, existing["id"], hash_password(password))
            await repo.revoke_all_for_user(pool, existing["id"])
            print(f"Senha de {args.username!r} alterada; sessões abertas encerradas.")
    finally:
        await close_pool()


def main() -> None:
    parser = argparse.ArgumentParser(prog="python -m app.auth.cli")
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("create-user")
    create.add_argument("username")
    create.add_argument("--admin", action="store_true")
    create.add_argument("--password-stdin", action="store_true")
    setpw = sub.add_parser("set-password")
    setpw.add_argument("username")
    setpw.add_argument("--password-stdin", action="store_true")
    sub.add_parser("list-users")
    asyncio.run(_main(parser.parse_args()))


if __name__ == "__main__":
    main()
