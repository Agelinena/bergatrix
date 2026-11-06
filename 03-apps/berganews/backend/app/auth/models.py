"""Modelos de entrada e saída da autenticação."""
from __future__ import annotations

from pydantic import BaseModel, Field, field_validator


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=1, max_length=512)


class UserOut(BaseModel):
    id: str
    username: str
    name: str
    email: str | None = None
    is_admin: bool

    @field_validator("id", mode="before")
    @classmethod
    def coerce_id(cls, v):
        return str(v)


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int
    user: UserOut


class AuthConfig(BaseModel):
    oidc_enabled: bool
    # "Gerenciar no Authentik" (nome, e-mail, senha, 2FA).
    account_url: str = ""


class OIDCExchange(BaseModel):
    code: str = Field(min_length=10, max_length=200)
    # PKCE do app: só quem começou o login consegue trocar o código.
    verifier: str = Field(min_length=43, max_length=128)
