"""POST /api/radio: a próxima leva de músicas de uma rádio.

O app guarda o estado da rádio (âncora, recentes ouvidas sem pular, artistas
pulados, o que já tocou) e manda a cada pedido; o servidor não guarda
sessão. Um pedido novo da mesma pessoa cancela o anterior que ainda estiver
rodando, e há um limite de rádios por minuto (429).
"""
from __future__ import annotations

import asyncio

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from app.auth.dependencies import CurrentUser, current_user
from app.radio import guard, match, service
from app.search.models import SearchResult

router = APIRouter(prefix="/api", tags=["radio"])


class Played(BaseModel):
    artist: str = Field(max_length=300)
    title: str = Field(max_length=300)


class RadioRequest(BaseModel):
    # Música que começou a rádio.
    seed: SearchResult
    # Até 2 recentes que a pessoa ouviu sem pular (as mais novas).
    recent: list[SearchResult] = Field(default_factory=list, max_length=2)
    # Artista -> quantas vezes foi pulado nesta rádio (antes dos 30 s).
    skipped: dict[str, int] = Field(default_factory=dict, max_length=200)
    # Já tocou nesta rádio ou está na fila: não repetir.
    exclude: list[Played] = Field(default_factory=list, max_length=600)
    # Último artista da fila (a leva não começa por ele).
    last_artist: str | None = Field(default=None, max_length=300)
    count: int = Field(default=15, ge=1, le=30)


class RadioResponse(BaseModel):
    tracks: list[SearchResult]
    sources: dict[str, str]


@router.post("/radio", response_model=RadioResponse)
async def radio(body: RadioRequest, user: CurrentUser = Depends(current_user)):
    try:
        await guard.check_rate(user.id)
    except guard.TooMany:
        raise HTTPException(429, detail="Muitas rádios seguidas. Espere um pouco.")
    exclude = {match.key(p.artist, p.title) for p in body.exclude}
    try:
        batch = await guard.run_latest(user.id, service.build(
            user.id, body.seed, body.recent, body.skipped, exclude, body.last_artist, body.count))
    except asyncio.CancelledError:
        # Substituído por um pedido mais novo desta pessoa (o app já ignora).
        raise HTTPException(409, detail="Substituída por uma rádio mais nova.")
    return RadioResponse(tracks=batch.tracks, sources=batch.sources)
