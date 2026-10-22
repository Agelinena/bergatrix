"""Gestão de contas: admin (criar, editar, desativar, senha), "minha conta",
esqueci a senha pelo link do e-mail, contas que vêm do Authentik e os
e-mails de aviso (capturados, sem SMTP).

Uso: docker compose exec -T api python tests/test_accounts.py
"""
from __future__ import annotations

import asyncio
import re
import secrets
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import asyncpg
import redis.asyncio as aioredis
from starlette.testclient import TestClient

from app.auth import oidc
from app.auth import repository as auth_repo
from app.auth.security import hash_password
from app.config import settings
from app.core import mail
from app.core.db import close_pool, create_pool
from app.main import app

P = F = 0
SENT: list = []


def ok(a, b, m=""):
    global P, F
    if a == b:
        P += 1
        print(f"  OK {m}")
    else:
        F += 1
        print(f"  FAIL {m}: {a!r} != {b!r}")


def inbox(to: str) -> list:
    return [m for m in SENT if m["To"] == to]


def body(message) -> str:
    return message.get_body(("plain",)).get_content()


def link_of(message) -> str:
    return re.search(r"https://\S+", body(message)).group(0).replace(
        "https://bergastream.example.com", "")


async def setup(tag):
    pool = await create_pool()
    admin = await auth_repo.create_user(pool, f"a_adm_{tag}", hash_password("senha-admin"), True,
                                        name=f"Admin {tag}")
    await close_pool()
    r = aioredis.from_url(settings.redis_url)
    await r.delete("bergastream:login_fail:esqueci-a-senha:testclient")
    await r.aclose()
    return str(admin["id"])


# Conexões próprias: create_pool/close_pool mexem no pool global da API.
async def sql(query, *args):
    conn = await asyncpg.connect(settings.database_url)
    try:
        return await conn.fetchval(query, *args)
    finally:
        await conn.close()


async def cleanup(tag):
    pool = await create_pool()
    await pool.execute("DELETE FROM users WHERE username ILIKE $1 OR name ILIKE $2",
                       f"%{tag}%", f"%{tag}%")
    await close_pool()


def login(c, username, password):
    return c.post("/api/auth/login", json={"username": username, "password": password})


def main():
    tag = secrets.token_hex(3)
    settings.oidc_issuer = ""
    settings.password_login = "true"
    settings.app_url = "https://bergastream.example.com"
    settings.smtp_from = "Bergastream <bergastream@example.com>"
    mail.set_transport(SENT.append)
    admin_id = asyncio.run(setup(tag))
    try:
        with TestClient(app) as c:
            adm = {"Authorization": "Bearer " + login(c, f"a_adm_{tag}", "senha-admin").json()["access_token"]}

            print("=== admin: criar e convidar ===")
            r = c.post("/api/admin/users", headers=adm, json={
                "username": f"ana_{tag}", "name": f"Ana {tag}", "email": f"Ana_{tag}@Example.com"})
            ok(r.status_code, 201, "conta criada")
            ana = r.json()
            ok((ana["email"], ana["has_password"]), (f"ana_{tag}@example.com", False),
               "e-mail minúsculo, sem senha")
            invite = inbox(f"ana_{tag}@example.com")
            ok(len(invite), 1, "convite enviado")
            path = link_of(invite[0])
            ok(path.startswith("/api/auth/password/reset?token="), True, "convite com link de senha")
            ok(c.get(path).status_code, 200, "link abre o formulário")
            token = path.split("token=")[1]
            r = c.post("/api/auth/password/reset", data={"token": token, "password": "nova-senha-1",
                                                         "confirm": "outra-coisa"})
            ok(r.status_code, 400, "senhas diferentes: recusa")
            r = c.post("/api/auth/password/reset", data={"token": token, "password": "nova-senha-1",
                                                         "confirm": "nova-senha-1"})
            ok(r.status_code, 200, "senha criada pelo link")
            ok(login(c, f"ana_{tag}", "nova-senha-1").status_code, 200, "entra com a senha nova")
            r = c.post("/api/auth/password/reset", data={"token": token, "password": "x" * 9,
                                                         "confirm": "x" * 9})
            ok(r.status_code, 400, "link só vale uma vez")
            ok(c.post("/api/admin/users", headers=adm, json={
                "username": f"outra_{tag}", "email": f"ana_{tag}@example.com"}).status_code, 409,
               "e-mail repetido: 409")
            ok(c.post("/api/admin/users", headers=adm, json={"username": "a b"}).status_code, 422,
               "usuário inválido: 422")

            ana_h = {"Authorization": "Bearer " + login(c, f"ana_{tag}", "nova-senha-1").json()["access_token"]}
            ok(c.get("/api/admin/users", headers=ana_h).status_code, 403, "não admin: 403")
            page = c.get("/api/admin/users", headers=adm).json()
            ok((page["mail_enabled"], any(u["id"] == ana["id"] for u in page["users"])), (True, True),
               "lista com a conta e o e-mail ligado")

            print("=== admin: editar e avisar ===")
            SENT.clear()
            r = c.patch(f"/api/admin/users/{ana['id']}", headers=adm, json={
                "username": f"anab_{tag}", "email": f"anab_{tag}@example.com"})
            ok((r.status_code, r.json()["username"]), (200, f"anab_{tag}"), "usuário e e-mail trocados")
            ok(len(inbox(f"ana_{tag}@example.com")), 0 + 1, "e-mail antigo avisado")
            ok(len(inbox(f"anab_{tag}@example.com")), 2, "e-mail novo: usuário trocado + boas-vindas")
            ok(c.patch(f"/api/admin/users/{admin_id}", headers=adm, json={"is_admin": False}).status_code,
               409, "não tira o próprio admin")
            ok(c.patch(f"/api/admin/users/{admin_id}", headers=adm, json={"disabled": True}).status_code,
               409, "não desativa a si mesmo")

            print("=== desativar ===")
            refresh = login(c, f"anab_{tag}", "nova-senha-1").json()["refresh_token"]
            SENT.clear()
            r = c.patch(f"/api/admin/users/{ana['id']}", headers=adm, json={"disabled": True})
            ok(r.json()["disabled"], True, "desativada")
            ok(len(SENT), 1, "pessoa avisada")
            r = login(c, f"anab_{tag}", "nova-senha-1")
            ok((r.status_code, r.json()["detail"]), (403, "Conta desativada"), "login: conta desativada")
            ok(c.post("/api/auth/refresh", json={"refresh_token": refresh}).status_code, 401,
               "sessões encerradas")
            c.patch(f"/api/admin/users/{ana['id']}", headers=adm, json={"disabled": False})
            ok(login(c, f"anab_{tag}", "nova-senha-1").status_code, 200, "reativada entra")

            print("=== senha pelo admin ===")
            refresh = login(c, f"anab_{tag}", "nova-senha-1").json()["refresh_token"]
            SENT.clear()
            r = c.post(f"/api/admin/users/{ana['id']}/password", headers=adm, json={"mode": "temporary"})
            temp = r.json()["password"]
            ok((len(temp), r.json()["sent"]), (12, True), "senha temporária devolvida e aviso enviado")
            ok("senha temporária" in body(SENT[0]) and temp not in body(SENT[0]), True,
               "o e-mail não leva a senha")
            ok(c.post("/api/auth/refresh", json={"refresh_token": refresh}).status_code, 401,
               "sessões antigas caem")
            ok(login(c, f"anab_{tag}", temp).status_code, 200, "entra com a temporária")
            SENT.clear()
            r = c.post(f"/api/admin/users/{ana['id']}/password", headers=adm, json={"mode": "link"})
            ok((r.status_code, len(SENT)), (200, 1), "link de senha por e-mail")

            print("=== minha conta ===")
            ana_h = {"Authorization": "Bearer " + login(c, f"anab_{tag}", temp).json()["access_token"]}
            me = c.get("/api/auth/account", headers=ana_h).json()
            ok((me["can_change_password"], me["account_url"]), (True, None), "pode trocar a senha aqui")
            r = c.patch("/api/auth/account", headers=ana_h, json={"name": f"Ana Beatriz {tag}"})
            ok(r.json()["name"], f"Ana Beatriz {tag}", "troca o próprio nome")
            r = c.post("/api/auth/account/password", headers=ana_h,
                       json={"current_password": "errada", "new_password": "senha-da-ana-2"})
            ok(r.status_code, 403, "senha atual errada")
            SENT.clear()
            r = c.post("/api/auth/account/password", headers=ana_h,
                       json={"current_password": temp, "new_password": "senha-da-ana-2"})
            ok((r.status_code, "access_token" in r.json(), len(SENT)), (200, True, 1),
               "troca a senha, recebe tokens novos e o aviso")

            print("=== esqueci a senha ===")
            SENT.clear()
            r = c.post("/api/auth/password/forgot", json={"login": f"anab_{tag}@example.com"})
            ok((r.status_code, len(SENT)), (202, 1), "pelo e-mail: link enviado")
            r = c.post("/api/auth/password/forgot", json={"login": f"ninguem_{tag}"})
            ok((r.status_code, len(SENT)), (202, 1), "conta que não existe: mesma resposta, nada enviado")
            for _ in range(3):
                c.post("/api/auth/password/forgot", json={"login": "x"})
            ok(c.post("/api/auth/password/forgot", json={"login": "x"}).status_code, 429,
               "limite de pedidos por IP")
            ok(c.get("/api/auth/config").json()["password_reset_enabled"], True,
               "config mostra o esqueci a senha")

            print("=== contas que vêm do Authentik ===")
            settings.oidc_issuer = "https://authentik.example.com/application/o/bergastream/"
            settings.oidc_client_id = "bergastream"
            settings.oidc_redirect_uri = "https://bergastream.example.com/api/auth/oidc/callback"
            r = c.patch("/api/auth/account", headers=ana_h, json={"email": f"outra_{tag}@example.com"})
            ok(r.status_code, 409, "ainda não ligada: a pessoa não troca o próprio e-mail")
            r = c.patch("/api/auth/account", headers=ana_h, json={"name": f"Ana B {tag}"})
            ok(r.status_code, 200, "o nome ela troca")
            r = c.post(f"/api/admin/users/{ana['id']}/notice", headers=adm,
                       json={"subject": "Oi\nBcc: x@example.com", "message": "teste"})
            ok((r.status_code, SENT[-1]["Subject"], SENT[-1]["Bcc"]), (200, "Oi Bcc: x@example.com", None),
               "assunto sem quebra de linha (sem cabeçalho extra)")
            asyncio.run(sql("UPDATE users SET oidc_subject = $2 WHERE id = $1",
                            ana["id"], f"sub-{tag}"))
            r = c.patch(f"/api/admin/users/{ana['id']}", headers=adm, json={"username": f"zz_{tag}"})
            ok(r.status_code, 409, "ligada: usuário só no Authentik")
            ok(c.post(f"/api/admin/users/{ana['id']}/password", headers=adm,
                      json={"mode": "temporary"}).status_code, 409, "ligada: senha só no Authentik")
            me = c.get("/api/auth/account", headers=ana_h).json()
            ok((me["managed_by_authentik"], me["account_url"]),
               (True, "https://authentik.example.com/if/user/#/settings"), "minha conta aponta para o Authentik")
            ok(c.patch(f"/api/admin/users/{ana['id']}", headers=adm, json={"is_admin": True}).status_code,
               200, "admin ainda dá para mudar (sem grupo de admin)")
            c.patch(f"/api/admin/users/{ana['id']}", headers=adm, json={"is_admin": False})

            identity = oidc.Identity(subject=f"sub-{tag}", username=f"ana.nova_{tag}",
                                     email=f"ana.nova_{tag}@example.com", name=f"Ana Nova {tag}",
                                     groups=())
            asyncio.run(_link(identity))
            row = c.get("/api/auth/account", headers=ana_h).json()
            ok((row["username"], row["email"], row["name"]),
               (f"ana.nova_{tag}", f"ana.nova_{tag}@example.com", f"Ana Nova {tag}"),
               "login pelo Authentik atualiza usuário, e-mail e nome")
            clash = oidc.Identity(subject=f"sub-{tag}", username=f"a_adm_{tag}",
                                  email=f"ana.nova_{tag}@example.com", name=f"Ana Nova {tag}", groups=())
            asyncio.run(_link(clash))
            ok(c.get("/api/auth/account", headers=ana_h).json()["username"], f"ana.nova_{tag}",
               "usuário que já é de outra conta: mantém o atual")

            c.patch(f"/api/admin/users/{ana['id']}", headers=adm, json={"disabled": True})
            try:
                asyncio.run(_link(identity))
                ok(True, False, "desativada não entra pelo Authentik")
            except oidc.OIDCError:
                ok(True, True, "desativada não entra pelo Authentik")
            r = c.post(f"/api/admin/users/{ana['id']}/unlink", headers=adm)
            ok(r.json()["linked"], False, "desligar do Authentik")

            print("=== e-mail ===")
            ok(c.post("/api/admin/mail/test", headers=adm).status_code, 409, "admin sem e-mail: 409")
            asyncio.run(sql("UPDATE users SET email = $2 WHERE id = $1", admin_id, f"adm_{tag}@example.com"))
            SENT.clear()
            ok(c.post("/api/admin/mail/test", headers=adm).status_code, 200, "teste enviado")
            r = c.post(f"/api/admin/users/{ana['id']}/notice", headers=adm,
                       json={"subject": "Troquei o servidor", "message": "Amanhã fica fora do ar."})
            ok((r.status_code, SENT[-1]["Subject"]), (200, "Troquei o servidor"), "aviso livre")
            html_part = SENT[-1].get_body(("html",)).get_content()
            ok("<script" not in html_part and "Amanhã" in html_part, True, "HTML escapado")
    finally:
        asyncio.run(cleanup(tag))
        mail.set_transport(None)
    print(f"\n{P}/{P + F} verificações passaram")
    sys.exit(1 if F else 0)


async def _link(identity):
    pool = await asyncpg.create_pool(settings.database_url, min_size=1, max_size=2)
    try:
        return await oidc.link_user(pool, identity)
    finally:
        await pool.close()


if __name__ == "__main__":
    main()
