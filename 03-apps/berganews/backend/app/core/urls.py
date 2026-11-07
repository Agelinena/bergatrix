"""Endereço canônico de uma matéria: sem redirecionador de clique, sem
parâmetro de rastreio, sem âncora.

A Folha manda no feed `https://redir.folha.com.br/redir/online/...*https://www1.folha...`,
e o UOL republica a mesma matéria com o endereço limpo: os dois precisam dar
o mesmo endereço para o Berganews saber que é uma republicação, e não um
segundo veículo contando a notícia.
"""
from __future__ import annotations

from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

_TRACKING = ("utm_", "fbclid", "gclid", "mc_cid", "mc_eid", "cmpid", "xtor", "ocid", "at_medium",
             "at_campaign", "ref_src", "__twitter_impression")


def canonical(url: str) -> str:
    url = (url or "").strip()
    # Redirecionador que leva o destino depois de "*" (Folha) ou num parâmetro.
    for marker in ("*https://", "*http://"):
        if marker in url:
            url = url[url.index(marker) + 1:]
            break
    parts = urlsplit(url)
    if not parts.scheme or not parts.netloc:
        return url
    query = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True)
             if not k.lower().startswith(_TRACKING)]
    return urlunsplit((parts.scheme.lower(), parts.netloc.lower(), parts.path,
                       urlencode(query), ""))
