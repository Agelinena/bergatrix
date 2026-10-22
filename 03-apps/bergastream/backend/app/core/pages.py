"""Páginas HTML simples abertas no navegador (erros do login pelo Authentik,
"redefinir senha" do link do e-mail)."""
from __future__ import annotations

import html

from fastapi.responses import HTMLResponse

_STYLE = """body{font-family:system-ui,sans-serif;background:#111;color:#eee;display:grid;
place-items:center;min-height:100vh;margin:0}main{max-width:28rem;padding:2rem;text-align:center}
a{color:#ff8a3d}form{display:grid;gap:.75rem;text-align:left}label{display:grid;gap:.25rem}
input{font:inherit;padding:.6rem .8rem;border-radius:.6rem;border:1px solid #444;background:#1c1c1c;
color:#eee}button{font:inherit;font-weight:600;padding:.7rem;border:0;border-radius:2rem;
background:#ff8a3d;color:#111;cursor:pointer}.err{color:#ff8a3d}"""


def page(title: str, message: str, back: str | None = None, *, body: str = "",
         status_code: int = 200) -> HTMLResponse:
    """[body] já vem em HTML (formulário); o resto é escapado aqui."""
    link = f'<p><a href="{html.escape(back)}">Voltar ao Bergastream</a></p>' if back else ""
    text = f"<p>{html.escape(message)}</p>" if message else ""
    return HTMLResponse(f"""<!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer"><title>{html.escape(title)}</title>
<style>{_STYLE}</style></head><body><main><h1>{html.escape(title)}</h1>{text}{body}{link}</main>
</body></html>""", status_code=status_code, headers={"Cache-Control": "no-store"})
