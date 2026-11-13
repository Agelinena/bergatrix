"""Teste de integração com Postgres de verdade (pgserver), sem Docker.

    pip install -r requirements.txt pgserver
    python tests/integration_pgserver.py . <pasta-temporária>

Passa pelas rotas HTTP (httpx + ASGI): login simulado, espaços, convites,
push/pull com dois aparelhos, conflitos, recusa, limpeza e concorrência.
"""
import asyncio
import os
import pathlib
import shutil
import sys
import uuid

BACKEND = pathlib.Path(sys.argv[1]).resolve()
DATA = pathlib.Path(sys.argv[2])
sys.path.insert(0, str(BACKEND))
os.environ["JWT_SECRET"] = "teste"
os.environ["OIDC_REDIRECT_URI"] = "https://doberga.example.com/api/auth/oidc/callback"

import pgserver  # noqa: E402

shutil.rmtree(DATA, ignore_errors=True)
srv = pgserver.get_server(str(DATA), cleanup_mode="stop")
os.environ["DATABASE_URL"] = srv.get_uri()

import asyncpg  # noqa: E402
import httpx  # noqa: E402

from app.auth import oidc, security  # noqa: E402
from app.core import db, redis as redis_mod  # noqa: E402
from app.main import app  # noqa: E402
from app.sync import engine  # noqa: E402
from app.sync.registry import Col, Table, register  # noqa: E402

PASS = 0


def check(cond, msg):
    global PASS
    if not cond:
        raise AssertionError(msg)
    PASS += 1
    print("  ok:", msg)


class FakeRedis:
    def __init__(self):
        self.kv, self.published = {}, []

    async def set(self, k, v, ex=None, nx=False):
        self.kv[k] = str(v)
        return True

    async def getdel(self, k):
        return self.kv.pop(k, None)

    async def publish(self, channel, payload):
        self.published.append((channel, payload))


TEST_TABLES = """
CREATE TABLE t_lists (
    id uuid PRIMARY KEY,
    space_id uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    rev bigint NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid REFERENCES users(id) ON DELETE SET NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid REFERENCES users(id) ON DELETE SET NULL,
    deleted_at timestamptz,
    name text NOT NULL
);
CREATE TRIGGER t_lists_sync BEFORE INSERT OR UPDATE ON t_lists FOR EACH ROW EXECUTE FUNCTION sync_touch();
CREATE TABLE t_items (
    id uuid PRIMARY KEY,
    space_id uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    rev bigint NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid REFERENCES users(id) ON DELETE SET NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid REFERENCES users(id) ON DELETE SET NULL,
    deleted_at timestamptz,
    list_id uuid NOT NULL REFERENCES t_lists(id) ON DELETE CASCADE,
    name text NOT NULL,
    quantity numeric CHECK (quantity >= 0),
    state text NOT NULL,
    due date
);
CREATE INDEX ON t_items (space_id, rev);
CREATE TRIGGER t_items_sync BEFORE INSERT OR UPDATE ON t_items FOR EACH ROW EXECUTE FUNCTION sync_touch();
CREATE TABLE t_events (
    id uuid PRIMARY KEY,
    space_id uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    rev bigint NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid REFERENCES users(id) ON DELETE SET NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid REFERENCES users(id) ON DELETE SET NULL,
    deleted_at timestamptz,
    item_id uuid NOT NULL,
    note text
);
CREATE TRIGGER t_events_sync BEFORE INSERT OR UPDATE ON t_events FOR EACH ROW EXECUTE FUNCTION sync_touch();
"""


def new_id():
    return str(uuid.uuid4())


def op(table, row_id, kind="upsert", **fields):
    return {"op_id": new_id(), "table": table, "row_id": row_id, "kind": kind, "fields": fields}


class Device:
    """Um aparelho: cursores próprios e um espelho local simples."""

    def __init__(self, client, user):
        self.client, self.user = client, user
        self.headers = {"Authorization": "Bearer " + security.create_access_token(str(user["id"]), user["is_admin"]),
                        "X-Doberga-Sync": "1"}
        self.cursors, self.rows, self.spaces = {}, {}, []
        self.device_id = new_id()

    async def push(self, *ops):
        r = await self.client.post("/api/sync/push", headers=self.headers,
                                   json={"device_id": self.device_id, "ops": list(ops)})
        assert r.status_code == 200, r.text
        return r.json()["results"]

    async def pull(self, limit=None):
        pages = 0
        while True:
            body = {"cursors": self.cursors}
            if limit:
                body["limit"] = limit
            r = await self.client.post("/api/sync/pull", headers=self.headers, json=body)
            assert r.status_code == 200, r.text
            data = r.json()
            pages += 1
            self.spaces = data["spaces"]
            ids = {s["id"] for s in data["spaces"]}
            for sid in data["reset"]:
                self.rows = {k: v for k, v in self.rows.items() if v["space_id"] != sid}
            self.rows = {k: v for k, v in self.rows.items() if v["space_id"] in ids}
            for ch in data["changes"]:
                row = ch["row"]
                if row["deleted_at"]:
                    self.rows.pop(row["id"], None)
                else:
                    self.rows[row["id"]] = row
            self.cursors = data["cursors"]
            if not data["has_more"]:
                return pages

    async def get(self, path):
        return await self.client.get(path, headers=self.headers)

    async def post(self, path, json=None):
        return await self.client.post(path, headers=self.headers, json=json or {})

    async def delete(self, path):
        return await self.client.delete(path, headers=self.headers)

    async def patch(self, path, json):
        return await self.client.patch(path, headers=self.headers, json=json)

    def personal(self):
        return next(s["id"] for s in self.spaces if s["kind"] == "personal")


async def main():
    for mig in sorted((BACKEND / "db/migrations").glob("*.sql")):
        up = mig.read_text(encoding="utf-8").split("-- migrate:down")[0].replace("-- migrate:up", "")
        conn = await asyncpg.connect(os.environ["DATABASE_URL"])
        await conn.execute(up)
        await conn.close()
        print("migração ok:", mig.name)
    conn = await asyncpg.connect(os.environ["DATABASE_URL"])
    await conn.execute(TEST_TABLES)
    await conn.close()

    register(Table("t_lists", {"name": Col("text", required=True, max_len=100)}))
    register(Table("t_items", {
        "list_id": Col("ref", required=True, ref="t_lists"),
        "name": Col("text", required=True, max_len=200),
        "quantity": Col("numeric", min=0, max=100000),
        "state": Col("enum", required=True, choices=("pending", "in_cart", "bought")),
        "due": Col("date"),
    }))
    register(Table("t_events", {"item_id": Col("uuid", required=True), "note": Col("text", max_len=500)},
                   append_only=True))

    pool = await db.create_pool()
    fake = FakeRedis()
    redis_mod._pool = fake

    print("\n== Login e espaço pessoal")
    ana = await oidc.link_user(pool, oidc.Identity("sub-ana", "ana", "ana@example.com", "Ana", ("doberga_users",)))
    bia = await oidc.link_user(pool, oidc.Identity("sub-bia", "bia", "bia@example.com", "Bia", ("doberga_users", "doberga_admins")))
    caio = await oidc.link_user(pool, oidc.Identity("sub-caio", "caio", "", "Caio", ("doberga_users",)))
    again = await oidc.link_user(pool, oidc.Identity("sub-ana", "ana", "ana@example.com", "Ana", ("doberga_users",)))
    check(again["id"] == ana["id"], "segundo login liga a mesma conta")
    n = await pool.fetchval("SELECT count(*) FROM spaces WHERE personal_user_id = $1", ana["id"])
    check(n == 1, "um espaço pessoal por pessoa, mesmo com vários logins")
    check(bia["is_admin"] and not ana["is_admin"], "admin vem do grupo do Authentik")

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://t") as client:
        a1, a2 = Device(client, ana), Device(client, ana)       # dois aparelhos da Ana
        b1, c1 = Device(client, bia), Device(client, caio)
        for d in (a1, a2, b1, c1):
            await d.pull()
        check(len(a1.spaces) == 1 and a1.spaces[0]["kind"] == "personal", "pull traz o espaço pessoal")

        r = await client.post("/api/sync/pull", headers={"Authorization": a1.headers["Authorization"]}, json={})
        check(r.status_code == 400, "sem X-Doberga-Sync: 400")
        r = await client.post("/api/sync/pull", headers={**a1.headers, "X-Doberga-Sync": "0"}, json={})
        check(r.status_code == 426, "protocolo antigo: 426 (atualizar o app)")

        print("\n== Push e pull no espaço pessoal")
        p = a1.personal()
        lst = new_id()
        item = new_id()
        res = await a1.push(op("t_lists", lst, space_id=p, name="Mercado"),
                            op("t_items", item, space_id=p, list_id=lst, name="Arroz", quantity="2.5",
                               state="pending", due="2026-11-20"))
        check([x["status"] for x in res] == ["ok", "ok"], "criar lista e item offline (IDs do aparelho)")
        await a2.pull()
        check(a2.rows[item]["name"] == "Arroz" and float(a2.rows[item]["quantity"]) == 2.5,
              "o outro aparelho da Ana recebe o item")
        check(a2.rows[item]["due"] == "2026-11-20", "data volta como AAAA-MM-DD")
        check(any(ch == f"doberga:user:{ana['id']}" for ch, _ in fake.published), "aviso publicado no canal da Ana")

        print("\n== Idempotência")
        dup = op("t_items", item, name="Arroz integral")
        r1 = await a1.push(dup)
        rev_after = await pool.fetchval("SELECT rev FROM t_items WHERE id = $1", item)
        r2 = await a1.push(dup)
        check(r1 == r2 and await pool.fetchval("SELECT rev FROM t_items WHERE id = $1", item) == rev_after,
              "reenviar a mesma operação não aplica de novo")
        r3 = await b1.push(dup)
        check(r3[0]["status"] == "rejected", "op_id de outra pessoa é recusado")

        print("\n== Acesso")
        res = await b1.push(op("t_items", item, name="Hackeado"))
        check(res[0]["status"] == "rejected" and res[0]["reason"] == "forbidden", "Bia não edita o espaço pessoal da Ana")
        res = await b1.push(op("t_items", new_id(), space_id=p, list_id=lst, name="X", state="pending"))
        check(res[0]["reason"] == "forbidden", "Bia não cria no espaço da Ana")
        await b1.pull()
        check(item not in b1.rows, "Bia não recebe nada da Ana")

        print("\n== Validação")
        res = await a1.push(op("t_items", new_id(), space_id=p, list_id=lst, name="Y", state="sumiu"))
        check(res[0]["reason"] == "invalid", "enum fora das opções")
        res = await a1.push(op("t_items", new_id(), space_id=p, list_id=lst, name="Y"))
        check(res[0]["reason"] == "invalid" and "state" in res[0]["message"], "campo obrigatório faltando")
        res = await a1.push(op("t_items", item, quantity=-1))
        check(res[0]["reason"] == "invalid", "número abaixo do mínimo")
        res = await a1.push(op("t_items", item, hacker="x"))
        check(res[0]["reason"] == "invalid", "campo desconhecido")
        res = await a1.push(op("t_items", item, name=None))
        check(res[0]["reason"] == "invalid", "obrigatório não vira nulo")
        res = await a1.push(op("t_nada", item, name="x"))
        check(res[0]["reason"] == "invalid", "tabela desconhecida")
        res = await a1.push(op("t_items", item, rev=1, updated_by=str(bia["id"])))
        row = await pool.fetchrow("SELECT updated_by FROM t_items WHERE id = $1", item)
        check(res[0]["status"] == "ok" and row["updated_by"] == ana["id"], "colunas do servidor são ignoradas")

        print("\n== Grupo e convite")
        r = await a1.post("/api/spaces", {"name": "Casa", "color": "#3366ff"})
        check(r.status_code == 201 and r.json()["role"] == "owner", "Ana cria o grupo Casa e é dona")
        casa = r.json()["id"]
        r = await b1.post(f"/api/spaces/{casa}/invites", {})
        check(r.status_code == 404, "quem não é membro não convida")
        r = await a1.post(f"/api/spaces/{p}/invites", {})
        check(r.status_code == 400, "espaço pessoal não aceita convite")
        r = await a1.post(f"/api/spaces/{casa}/invites", {"uses": 2})
        token = r.json()["token"]
        check(r.json()["url"].endswith(f"/convite/{token}"), "link do convite no domínio do app")
        r = await b1.get(f"/api/invites/{token}")
        check(r.status_code == 200 and r.json()["space_name"] == "Casa" and r.json()["inviter"] == "Ana",
              "Bia vê o convite antes de aceitar")
        r = await b1.post(f"/api/invites/{token}/accept")
        check(r.status_code == 200 and r.json()["role"] == "member", "Bia entra como membro")
        r = await b1.post(f"/api/invites/{token}/accept")
        check(r.status_code == 200, "aceitar de novo não gasta uso")
        r = await c1.post(f"/api/invites/{token}/accept")
        check(r.status_code == 200, "Caio entra (segundo uso)")
        r = await c1.post(f"/api/invites/{token}/accept")
        r2 = await Device(client, again).post(f"/api/invites/{token}/accept")
        check(r2.status_code == 404, "convite esgotado")
        r = await b1.post(f"/api/invites/{'x' * 30}/accept")
        check(r.status_code == 404, "convite inválido")

        print("\n== Dois aparelhos no mercado (mesmo item, campos diferentes)")
        await a1.pull(); await b1.pull(); await c1.pull()
        check(any(s["id"] == casa for s in b1.spaces), "o grupo aparece no pull da Bia")
        lc, ic = new_id(), new_id()
        await a1.push(op("t_lists", lc, space_id=casa, name="Feira"),
                      op("t_items", ic, space_id=casa, list_id=lc, name="Banana", quantity=6, state="pending"))
        await b1.pull()
        check(b1.rows[ic]["name"] == "Banana", "Bia recebe o item do grupo")
        # Offline: Ana muda a quantidade, Bia marca no carrinho. Os dois mandam depois.
        await a1.push(op("t_items", ic, quantity=12))
        await b1.push(op("t_items", ic, state="in_cart"))
        await c1.pull()
        check(float(c1.rows[ic]["quantity"]) == 12 and c1.rows[ic]["state"] == "in_cart",
              "campos diferentes: as duas alterações ficam")
        await a1.push(op("t_items", ic, name="Banana prata"))
        await b1.push(op("t_items", ic, name="Banana nanica"))
        await c1.pull()
        check(c1.rows[ic]["name"] == "Banana nanica", "mesmo campo: vale a última que chegou")

        print("\n== Apagar")
        await b1.push(op("t_items", ic, kind="delete"))
        res = await a1.push(op("t_items", ic, quantity=1))
        check(res[0]["reason"] == "deleted", "editar algo apagado é recusado (deleted)")
        res = await a1.push(op("t_items", ic, kind="delete"))
        check(res[0]["status"] == "ok", "apagar de novo é ok")
        res = await a1.push(op("t_items", new_id(), kind="delete"))
        check(res[0]["status"] == "ok", "apagar algo que nunca chegou ao servidor é ok")
        await c1.pull()
        check(ic not in c1.rows, "a exclusão chega aos outros")

        print("\n== Espaço e referências")
        res = await a1.push(op("t_items", item, space_id=casa))
        check(res[0]["reason"] == "invalid", "linha não muda de espaço")
        res = await a1.push(op("t_items", new_id(), space_id=casa, list_id=lst, name="Z", state="pending"))
        check(res[0]["reason"] == "invalid", "referência para lista de outro espaço é recusada")

        print("\n== Eventos (só criar e apagar)")
        ev = new_id()
        res = await a1.push(op("t_events", ev, space_id=casa, item_id=item, note="feito"))
        check(res[0]["status"] == "ok", "criar evento")
        res = await a1.push(op("t_events", ev, note="mudado"))
        check(res[0]["reason"] == "invalid", "evento não se edita")
        res = await a1.push(op("t_events", ev, kind="delete"))
        check(res[0]["status"] == "ok", "evento se apaga (desfazer)")

        print("\n== Paginação")
        many = [op("t_items", new_id(), space_id=casa, list_id=lc, name=f"I{i}", state="pending") for i in range(25)]
        await a1.push(*many)
        fresh = Device(client, bia)
        pages = await fresh.pull(limit=7)
        expected = await pool.fetchval(
            "SELECT count(*) FROM t_items WHERE space_id = $1 AND deleted_at IS NULL", uuid.UUID(casa))
        got = sum(1 for r in fresh.rows.values() if r.get("list_id") and r["space_id"] == casa)
        check(pages > 3 and got == expected, f"aparelho novo baixa tudo em páginas ({pages} páginas, {got} itens)")
        check(all(not r["deleted_at"] for r in fresh.rows.values()), "aparelho novo não recebe lápides")

        print("\n== Concorrência (o pull nunca pula linha)")
        watcher = Device(client, caio)
        await watcher.pull()

        async def writer(k):
            d = Device(client, ana if k % 2 else bia)
            for j in range(10):
                await d.push(op("t_items", new_id(), space_id=casa, list_id=lc, name=f"C{k}-{j}", state="pending"))

        async def reader():
            for _ in range(30):
                await watcher.pull(limit=5)
                await asyncio.sleep(0)

        await asyncio.gather(*(writer(k) for k in range(6)), reader())
        await watcher.pull()
        db_ids = {str(r["id"]) for r in await pool.fetch(
            "SELECT id FROM t_items WHERE space_id = $1 AND deleted_at IS NULL", uuid.UUID(casa))}
        local = {k for k, v in watcher.rows.items() if v["space_id"] == casa and "list_id" in v}
        check(db_ids == local, f"leitor incremental com 6 escritores: {len(local)} itens, nenhum perdido")

        print("\n== Membros")
        r = await b1.delete(f"/api/spaces/{casa}/members/{caio['id']}")
        check(r.status_code == 403, "membro não remove outro")
        r = await a1.delete(f"/api/spaces/{casa}/members/{ana['id']}")
        check(r.status_code == 400, "última dona não sai sem passar o grupo")
        r = await a1.patch(f"/api/spaces/{casa}/members/{ana['id']}", {"role": "member"})
        check(r.status_code == 400, "o grupo não fica sem dono")
        r = await c1.delete(f"/api/spaces/{casa}/members/{caio['id']}")
        check(r.status_code == 204, "Caio sai do grupo")
        await c1.pull()
        check(all(v["space_id"] != casa for v in c1.rows.values()) and len(c1.spaces) == 1,
              "quem sai perde o espaço e os dados no aparelho")
        res = await c1.push(op("t_items", item, name="x"))
        check(res[0]["reason"] == "forbidden", "quem saiu não grava mais")
        r = await a1.patch(f"/api/spaces/{casa}/members/{bia['id']}", {"role": "owner"})
        check(r.status_code == 200, "Ana torna a Bia dona")
        r = await a1.delete(f"/api/spaces/{casa}/members/{ana['id']}")
        check(r.status_code == 204, "agora a Ana pode sair")
        r = await b1.patch(f"/api/spaces/{casa}", {"name": "Casa nova"})
        check(r.status_code == 200 and r.json()["name"] == "Casa nova", "dona renomeia")

        print("\n== Limpeza e reset")
        stale = Device(client, bia)
        await stale.pull()
        before = dict(stale.cursors)
        gone = new_id()
        await b1.push(op("t_items", gone, space_id=casa, list_id=lc, name="Velho", state="pending"))
        await stale.pull()
        await b1.push(op("t_items", gone, kind="delete"))
        stale.cursors = before
        await pool.execute("UPDATE t_items SET deleted_at = now() - interval '100 days' WHERE deleted_at IS NOT NULL")
        done = await engine.cleanup(pool, 90)
        check(done["rows"] >= 2, f"lápides antigas apagadas de vez ({done['rows']})")
        r = await client.post("/api/sync/pull", headers=stale.headers, json={"cursors": stale.cursors})
        check(casa in r.json()["reset"], "aparelho parado há muito tempo refaz o espaço")
        await stale.pull()
        check(gone not in stale.rows, "e não fica com o item que foi apagado")

        print("\n== Apagar o grupo")
        r = await b1.delete(f"/api/spaces/{casa}")
        check(r.status_code == 204, "dona apaga o grupo")
        n = await pool.fetchval("SELECT count(*) FROM t_items WHERE space_id = $1", uuid.UUID(casa))
        check(n == 0, "os dados do grupo somem junto")
        r = await b1.delete(f"/api/spaces/{b1.personal()}")
        check(r.status_code == 400, "espaço pessoal não se apaga")

        print("\n== Sessão com sinal ruim")
        from app.auth import service
        from app.config import settings
        pair = await service.issue_for(pool, ana, "teste")
        new = await service.refresh(pool, pair.refresh_token, "teste")
        retry = await service.refresh(pool, pair.refresh_token, "teste")
        check(bool(retry.access_token), "token recém-trocado ainda vale (resposta perdida)")
        await pool.execute("UPDATE refresh_tokens SET revoked_at = now() - interval '10 minutes' WHERE token_hash = $1",
                           security.hash_refresh_token(pair.refresh_token))
        try:
            await service.refresh(pool, pair.refresh_token, "teste")
            check(False, "reuso tardio deveria falhar")
        except service.InvalidRefreshToken:
            check(True, "reuso depois da tolerância é recusado")
        try:
            await service.refresh(pool, new.refresh_token, "teste")
            check(False, "família deveria estar revogada")
        except service.InvalidRefreshToken:
            check(True, "e derruba a sessão inteira (sinal de roubo)")
        _ = settings

        print("\n== Admin e preferências")
        r = await b1.get("/api/admin/users")
        check(r.status_code == 200 and {u["username"] for u in r.json()} >= {"ana", "bia", "caio"}, "admin lista usuários")
        r = await a1.get("/api/admin/users")
        check(r.status_code == 403, "não-admin não vê a página Usuários")
        r = await a1.get("/api/prefs")
        tabs = r.json()["tabs"]
        check(tabs[0]["id"] == "today" and not next(t for t in tabs if t["id"] == "shopping")["available"],
              "abas: Hoje ligada, módulos futuros indisponíveis")
        r = await client.put("/api/prefs", headers=a1.headers, json={"notify_hour": 7, "theme": "dark"})
        check(r.json()["notify_hour"] == 7 and r.json()["theme"] == "dark", "salvar preferências")
        r = await client.get("/api/app/version")
        check(r.json()["sync_protocol"] == 1, "versão do app e do protocolo")

    await db.close_pool()
    print(f"\nTUDO OK: {PASS} verificações")


try:
    asyncio.run(main())
finally:
    srv.cleanup()
