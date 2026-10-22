"""Modelos de entrada e saída da autenticação."""
from __future__ import annotations

from pydantic import BaseModel, Field, field_validator


class Credentials(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=256)


class RegisterRequest(BaseModel):
    username: str = Field(min_length=3, max_length=32, pattern=r"^[A-Za-z0-9_.-]+$")
    password: str = Field(min_length=8, max_length=256)


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=1, max_length=512)


class UserOut(BaseModel):
    id: str
    username: str
    name: str
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
    registration_enabled: bool
    # Login pelo Authentik (botão "Entrar com o Authentik") e por senha.
    oidc_enabled: bool = False
    password_login_enabled: bool = True
    # "Esqueci minha senha" (senha ligada, SMTP e endereço do app configurados).
    password_reset_enabled: bool = False


class OIDCExchange(BaseModel):
    code: str = Field(min_length=10, max_length=200)
    # PKCE do app: só quem começou o login consegue trocar o código.
    verifier: str = Field(min_length=43, max_length=128)


class StreamToken(BaseModel):
    token: str
    expires_in: int
