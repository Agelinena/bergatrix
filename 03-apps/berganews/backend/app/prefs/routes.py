"""Preferências de cada pessoa (painel "Aparência"): /api/prefs.

As abas são uma lista ordenada; a pessoa liga, desliga e reordena. Uma aba
marcada como indisponível em TABS vem na lista desligada, para o app saber
que está chegando.
"""
from __future__ import annotations

import json

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field

from app.auth.dependencies import CurrentUser, current_user
from app.config import settings
from app.core.db import get_pool

router = APIRouter(prefix="/api/prefs", tags=["prefs"])

# id → disponível nesta versão
TABS = {
    "all": True,        # Todas, por ordem de publicação
    "sources": True,    # Por veículo
    "folders": True,    # Por pasta
    "saved": True,      # Salvos
    "stories": True,    # Agrupadas pela IA (histórias)
}
DEFAULT_TABS = ["all", "sources", "folders", "stories", "saved"]


class Tab(BaseModel):
    id: str
    enabled: bool
    available: bool = True


class Prefs(BaseModel):
    tabs: list[Tab]
    language: str = "pt"                 # idioma de leitura (alvo da tradução)
    theme: str = Field("system", pattern="^(system|light|dark)$")
    text_scale: float = Field(1.0, ge=0.8, le=1.6)
    open_original: bool = False          # abrir no site em vez do leitor
    mark_read_on_open: bool = True


class PrefsIn(BaseModel):
    tabs: list[Tab] | None = None
    language: str | None = None
    theme: str | None = Field(None, pattern="^(system|light|dark)$")
    text_scale: float | None = Field(None, ge=0.8, le=1.6)
    open_original: bool | None = None
    mark_read_on_open: bool | None = None


def merge(stored: dict) -> Prefs:
    """Preferências guardadas + padrões: aba nova entra no fim, aba que saiu
    some, e as indisponíveis ficam desligadas."""
    seen, tabs = set(), []
    for tab in stored.get("tabs") or []:
        tab_id = tab.get("id") if isinstance(tab, dict) else None
        if tab_id in TABS and tab_id not in seen:
            seen.add(tab_id)
            tabs.append(Tab(id=tab_id, enabled=bool(tab.get("enabled")) and TABS[tab_id],
                            available=TABS[tab_id]))
    for tab_id in DEFAULT_TABS:
        if tab_id not in seen:
            tabs.append(Tab(id=tab_id, enabled=TABS[tab_id], available=TABS[tab_id]))
    if not any(t.enabled for t in tabs):
        tabs[0].enabled = True
    values = {k: v for k, v in stored.items() if k != "tabs" and k in Prefs.model_fields}
    try:
        prefs = Prefs(tabs=tabs, **values)
    except ValueError:
        prefs = Prefs(tabs=tabs)
    if prefs.language not in settings.translate_langs:
        prefs.language = settings.translate_langs[0] if settings.translate_langs else "pt"
    return prefs


async def load(pool, user_id: str) -> Prefs:
    raw = await pool.fetchval("SELECT prefs FROM user_prefs WHERE user_id = $1", user_id)
    return merge(json.loads(raw) if raw else {})


@router.get("", response_model=Prefs)
async def get_prefs(user: CurrentUser = Depends(current_user)):
    return await load(get_pool(), user.id)


@router.put("", response_model=Prefs)
async def put_prefs(body: PrefsIn, user: CurrentUser = Depends(current_user)):
    pool = get_pool()
    current = (await load(pool, user.id)).model_dump()
    changes = body.model_dump(exclude_none=True)
    if "language" in changes and changes["language"] not in settings.translate_langs:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY,
                            detail=f"Idiomas aceitos: {', '.join(settings.translate_langs)}")
    current.update(changes)
    prefs = merge(current)
    stored = prefs.model_dump()
    stored["tabs"] = [{"id": t.id, "enabled": t.enabled} for t in prefs.tabs]
    await pool.execute(
        """INSERT INTO user_prefs (user_id, prefs, updated_at) VALUES ($1, $2::jsonb, now())
           ON CONFLICT (user_id) DO UPDATE SET prefs = EXCLUDED.prefs, updated_at = now()""",
        user.id, json.dumps(stored))
    return prefs
