"""Preferências de cada pessoa: /api/prefs.

As abas são uma lista ordenada; a pessoa liga, desliga e reordena. Uma aba de
módulo que ainda não existe nesta versão vem desligada e marcada como
indisponível, para o app saber que está chegando.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from app.auth.dependencies import CurrentUser, current_user
from app.core.db import get_pool

router = APIRouter(prefix="/api/prefs", tags=["prefs"])

# id → disponível nesta versão (cada fase liga o seu módulo)
TABS = {
    "today": True,       # Hoje e Semana
    "shopping": False,   # Lista de compras (fase 1)
    "recurring": False,  # Recorrentes (fase 2)
    "calendar": False,   # Calendário (fase 3)
    "notes": False,      # Notas (fase 4)
}
DEFAULT_TABS = ["today", "shopping", "recurring", "calendar", "notes"]
MODULES = ("shopping", "recurring", "calendar", "notes")


class Tab(BaseModel):
    id: str
    enabled: bool
    available: bool = True


class Prefs(BaseModel):
    tabs: list[Tab]
    theme: str = Field("system", pattern="^(system|light|dark)$")
    # Espaço que abre por padrão em cada módulo (id do espaço).
    default_spaces: dict[str, str] = Field(default_factory=dict)
    # Hora dos avisos de recorrentes, no fuso do aparelho.
    notify_hour: int = Field(9, ge=0, le=23)
    week_start: str = Field("monday", pattern="^(monday|sunday)$")


class PrefsIn(BaseModel):
    tabs: list[Tab] | None = None
    theme: str | None = Field(None, pattern="^(system|light|dark)$")
    default_spaces: dict[str, str] | None = None
    notify_hour: int | None = Field(None, ge=0, le=23)
    week_start: str | None = Field(None, pattern="^(monday|sunday)$")


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
    spaces = values.get("default_spaces")
    if isinstance(spaces, dict):
        values["default_spaces"] = {k: str(v) for k, v in spaces.items() if k in MODULES and v}
    try:
        return Prefs(tabs=tabs, **values)
    except ValueError:
        return Prefs(tabs=tabs)


async def load(pool, user_id: str) -> Prefs:
    stored = await pool.fetchval("SELECT prefs FROM user_prefs WHERE user_id = $1", user_id)
    return merge(stored or {})


@router.get("", response_model=Prefs)
async def get_prefs(user: CurrentUser = Depends(current_user)):
    return await load(get_pool(), user.id)


@router.put("", response_model=Prefs)
async def put_prefs(body: PrefsIn, user: CurrentUser = Depends(current_user)):
    pool = get_pool()
    current = (await load(pool, user.id)).model_dump()
    current.update(body.model_dump(exclude_none=True))
    prefs = merge(current)
    stored = prefs.model_dump()
    stored["tabs"] = [{"id": t.id, "enabled": t.enabled} for t in prefs.tabs]
    await pool.execute(
        """INSERT INTO user_prefs (user_id, prefs, updated_at) VALUES ($1, $2, now())
           ON CONFLICT (user_id) DO UPDATE SET prefs = EXCLUDED.prefs, updated_at = now()""",
        user.id, stored)
    return prefs
