"""Registro das tabelas sincronizadas.

Cada módulo declara aqui as suas tabelas: quais colunas o aparelho pode
escrever, o tipo e as regras de cada uma. O sync (push e pull) só lê e grava
o que está registrado; nomes de tabela e coluna nunca vêm do aparelho direto
para o SQL.

A tabela no banco segue o contrato da migração do núcleo (colunas padrão +
trigger sync_touch).

Exemplo (módulo de compras):

    register(Table("shopping_items", {
        "list_id": Col("ref", required=True, ref="shopping_lists"),
        "name": Col("text", required=True, max_len=200),
        "quantity": Col("numeric", min=0, max=100000),
        "state": Col("enum", required=True, choices=("pending", "in_cart", "bought")),
    }))
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import date, datetime
from decimal import Decimal, InvalidOperation
from uuid import UUID

# Colunas que toda tabela sincronizada tem. O aparelho só escreve `space_id`
# (ao criar); o resto é do servidor.
STANDARD = ("id", "space_id", "rev", "created_at", "created_by", "updated_at", "updated_by",
            "deleted_at")

KINDS = {"text", "int", "numeric", "bool", "date", "timestamptz", "uuid", "enum", "json", "ref"}
_NAME = re.compile(r"^[a-z][a-z0-9_]{0,62}$")


@dataclass(frozen=True)
class Col:
    kind: str
    required: bool = False          # obrigatório ao criar; não pode virar nulo depois
    max_len: int | None = None      # text, json (tamanho do JSON)
    choices: tuple[str, ...] = ()   # enum
    min: float | None = None        # int, numeric
    max: float | None = None
    ref: str | None = None          # ref: tabela sincronizada do mesmo espaço

    def __post_init__(self):
        if self.kind not in KINDS:
            raise ValueError(f"tipo desconhecido: {self.kind}")
        if self.kind == "enum" and not self.choices:
            raise ValueError("enum sem opções")
        if self.kind == "ref" and not self.ref:
            raise ValueError("ref sem tabela")


@dataclass(frozen=True)
class Table:
    name: str
    columns: dict[str, Col] = field(default_factory=dict)
    # Eventos (feito, compra fechada): só se cria e apaga, nunca se edita.
    append_only: bool = False

    def __post_init__(self):
        if not _NAME.match(self.name):
            raise ValueError(f"nome de tabela inválido: {self.name}")
        for name in self.columns:
            if not _NAME.match(name) or name in STANDARD:
                raise ValueError(f"coluna inválida em {self.name}: {name}")

    @property
    def required(self) -> list[str]:
        return [n for n, c in self.columns.items() if c.required]


TABLES: dict[str, Table] = {}


def register(table: Table) -> Table:
    for col in table.columns.values():
        if col.ref and col.ref not in TABLES and col.ref != table.name:
            raise ValueError(f"{table.name}: registre {col.ref} antes")
    TABLES[table.name] = table
    return table


def unregister(name: str) -> None:
    """Testes."""
    TABLES.pop(name, None)


class Invalid(ValueError):
    """Valor recusado (mensagem mostrada à pessoa)."""


def coerce(name: str, col: Col, value):
    """Valor do JSON do aparelho → valor Python para o asyncpg."""
    if value is None:
        if col.required:
            raise Invalid(f"{name} é obrigatório")
        return None
    kind = col.kind
    try:
        if kind == "text":
            if not isinstance(value, str):
                raise Invalid(f"{name} precisa ser texto")
            if col.max_len and len(value) > col.max_len:
                raise Invalid(f"{name} passa de {col.max_len} caracteres")
            if col.required and not value.strip():
                raise Invalid(f"{name} é obrigatório")
            return value
        if kind == "enum":
            if value not in col.choices:
                raise Invalid(f"{name}: valor não aceito")
            return value
        if kind == "bool":
            if not isinstance(value, bool):
                raise Invalid(f"{name} precisa ser verdadeiro ou falso")
            return value
        if kind == "int":
            if isinstance(value, bool) or not isinstance(value, int):
                raise Invalid(f"{name} precisa ser um número inteiro")
            _range(name, col, value)
            return value
        if kind == "numeric":
            if isinstance(value, bool) or not isinstance(value, (int, float, str)):
                raise Invalid(f"{name} precisa ser um número")
            number = Decimal(str(value))
            if not number.is_finite():
                raise Invalid(f"{name} precisa ser um número")
            _range(name, col, number)
            return number
        if kind == "date":
            return date.fromisoformat(value)
        if kind == "timestamptz":
            parsed = datetime.fromisoformat(value)
            if parsed.tzinfo is None:
                raise Invalid(f"{name} precisa do fuso horário")
            return parsed
        if kind in ("uuid", "ref"):
            return UUID(value)
        if kind == "json":
            import json
            if col.max_len and len(json.dumps(value)) > col.max_len:
                raise Invalid(f"{name} é grande demais")
            return value
    except Invalid:
        raise
    except (TypeError, ValueError, InvalidOperation, AttributeError):
        raise Invalid(f"{name}: valor inválido") from None
    raise Invalid(f"{name}: tipo não suportado")


def _range(name: str, col: Col, value) -> None:
    if col.min is not None and value < Decimal(str(col.min)):
        raise Invalid(f"{name} abaixo do mínimo")
    if col.max is not None and value > Decimal(str(col.max)):
        raise Invalid(f"{name} acima do máximo")
