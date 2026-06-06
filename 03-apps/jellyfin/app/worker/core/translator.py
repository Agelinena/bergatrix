import os
import time
import threading
import httpx
import logging
import re
from .utils import save_subtitle

logger = logging.getLogger(__name__)

OPENROUTER_API_URL = "https://openrouter.ai/api/v1/chat/completions"
OPENROUTER_MODELS_URL = "https://openrouter.ai/api/v1/models"
GEMINI_API_URL = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
CHUNK_DURATION = 900  # 15 minutos por chunk

# Famílias gratuitas preferidas (ordem = prioridade), melhores para PT-BR primeiro.
# Os modelos REAIS são DESCOBERTOS dinamicamente via /api/v1/models, porque os
# slugs ":free" mudam o tempo todo (e dão 404 se hardcoded). Configurável por env.
DEFAULT_FREE_FAMILIES = ["deepseek", "qwen", "meta-llama", "mistralai", "google"]
FREE_DISCOVERY_TTL = 6 * 3600  # re-descobre os modelos gratuitos a cada 6h

SYSTEM_PROMPT = (
    "Você é um tradutor profissional de legendas (SRT). "
    "Traduza o conteúdo abaixo para Português do Brasil (pt-br). "
    "Adapte gírias e expressões para o contexto brasileiro. "
    "NÃO altere a quantidade de linhas de diálogo. "
    "Retorne APENAS o texto traduzido no formato SRT, sem explicações."
)


class Translator:
    def __init__(self):
        self.api_key = os.environ.get("OPENROUTER_API_KEY", "")
        # Modelo pago padrão (preferencial)
        self.model = os.environ.get("OPENROUTER_MODEL", "deepseek/deepseek-chat-v3-0324")

        # Cadeia de fallback de IA: Gemini chave 1 → Gemini chave 2 → OpenRouter pago → OpenRouter grátis.
        self.gemini_keys = [k.strip() for k in (os.environ.get("GEMINI_API_1", ""),
                                                os.environ.get("GEMINI_API_2", "")) if k.strip()]
        self.gemini_model = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")
        self._gemini_dead = set()   # chaves inválidas/sem acesso nesta sessão

        # Override fixo (CSV) tem prioridade; senão descobre por família dinamicamente.
        free_env = os.environ.get("OPENROUTER_FREE_MODELS", "").strip()
        self._free_override = [m.strip() for m in free_env.split(",") if m.strip()] if free_env else None
        fam_env = os.environ.get("OPENROUTER_FREE_FAMILIES", "").strip()
        self.free_families = [f.strip().lower() for f in fam_env.split(",") if f.strip()] or DEFAULT_FREE_FAMILIES

        self.max_free = int(os.environ.get("MAX_FREE_FALLBACKS", "4"))
        self.paid_available = True          # 402 no pago → desliga pelo resto da sessão
        self.dead_models = set()            # slugs que retornaram 404 nesta sessão
        self._free_cache = None
        self._free_cache_at = 0.0
        self._lock = threading.Lock()       # serializa traduções concorrentes (scanner + jobs)

        if not self.api_key and not self.gemini_keys:
            raise ValueError("Nenhuma API de IA configurada (OPENROUTER_API_KEY ou GEMINI_API_1/GEMINI_API_2).")

        modo = f"override fixo: {self._free_override}" if self._free_override else f"descoberta por família {self.free_families}"
        logger.info(
            f"Translator inicializado. Cadeia: Gemini x{len(self.gemini_keys)} ({self.gemini_model}) "
            f"→ OpenRouter pago ({self.model}) → OpenRouter grátis ({modo}; máx {self.max_free})"
        )

    # ------------------------------------------------------------------ #
    # Descoberta dinâmica dos modelos gratuitos                            #
    # ------------------------------------------------------------------ #

    def _discover_free_models(self) -> list:
        """Consulta /api/v1/models e retorna os modelos ':free' das famílias preferidas, ordenados."""
        try:
            with httpx.Client(timeout=30) as c:
                r = c.get(OPENROUTER_MODELS_URL, headers={"Authorization": f"Bearer {self.api_key}"})
                r.raise_for_status()
                data = r.json().get("data", [])
        except Exception as e:
            logger.warning(f"Falha ao descobrir modelos gratuitos no OpenRouter: {e}")
            return []

        free_ids = []
        for m in data:
            mid = m.get("id", "")
            pricing = m.get("pricing", {}) or {}
            is_free = mid.endswith(":free") or (
                str(pricing.get("prompt", "1")) in ("0", "0.0")
                and str(pricing.get("completion", "1")) in ("0", "0.0")
            )
            if is_free and mid:
                free_ids.append(mid)

        # Ordena por prioridade de família; ignora famílias fora da lista preferida
        ordered = []
        for fam in self.free_families:
            for mid in free_ids:
                if mid.split("/")[0].lower() == fam or mid.lower().startswith(fam):
                    if mid not in ordered:
                        ordered.append(mid)
        logger.info(f"Modelos gratuitos ATIVOS descobertos ({len(ordered)}): {ordered[:8]}")
        return ordered

    def _get_free_models(self) -> list:
        """Retorna a lista de modelos gratuitos (override fixo, ou descoberta com cache de 6h)."""
        if self._free_override is not None:
            return self._free_override
        now = time.time()
        if self._free_cache is None or (now - self._free_cache_at) > FREE_DISCOVERY_TTL:
            discovered = self._discover_free_models()
            if discovered:
                self._free_cache = discovered
                self._free_cache_at = now
            elif self._free_cache is None:
                self._free_cache = []
        return self._free_cache

    def _request_gemini(self, api_key: str, text_content: str) -> tuple[str | None, str]:
        """Traduz um chunk via Gemini (Google). Retorna (conteudo, motivo)."""
        url = GEMINI_API_URL.format(model=self.gemini_model)
        payload = {
            "systemInstruction": {"parts": [{"text": SYSTEM_PROMPT}]},
            "contents": [{"role": "user", "parts": [{"text": text_content}]}],
        }
        try:
            with httpx.Client(timeout=180.0) as client:
                r = client.post(url, params={"key": api_key}, json=payload)
            if r.status_code == 200:
                cands = r.json().get("candidates") or []
                if not cands:
                    return None, "error"
                parts = (cands[0].get("content") or {}).get("parts") or []
                text = "".join(p.get("text", "") for p in parts)
                return (text, "ok") if text and text.strip() else (None, "error")
            if r.status_code == 429:
                return None, "rate_limited"           # cota/RPM esgotada
            if r.status_code in (400, 401, 403):
                return None, "no_credit"              # chave inválida / sem acesso
            logger.error(f"[gemini] HTTP {r.status_code}: {r.text[:160]}")
            return None, "error"
        except httpx.TimeoutException:
            return None, "timeout"
        except Exception as e:
            logger.error(f"[gemini] erro inesperado: {e}")
            return None, "error"

    def _request_model(self, model: str, text_content: str) -> tuple[str | None, str]:
        """
        Tenta UM modelo, UMA única vez. Retorna (conteudo, motivo).
        motivo ∈ {"ok", "no_credit", "not_found", "rate_limited", "timeout", "error"}.
        Sem retry longo aqui — quem chama passa ao PRÓXIMO modelo (há vários gratuitos).
        """
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://github.com/legendarr",
            "X-Title": "Legendarr",
        }
        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": text_content},
            ],
        }
        try:
            with httpx.Client(timeout=180.0) as client:
                response = client.post(OPENROUTER_API_URL, headers=headers, json=payload)

            if response.status_code == 200:
                choices = response.json().get("choices") or []
                if not choices:
                    return None, "error"
                content = choices[0].get("message", {}).get("content", "")
                return (content, "ok") if content and content.strip() else (None, "error")
            if response.status_code in (401, 402):
                return None, "no_credit"
            if response.status_code == 404:
                return None, "not_found"
            if response.status_code == 429:
                return None, "rate_limited"
            logger.error(f"[{model}] HTTP {response.status_code}: {response.text[:160]}")
            return None, "error"
        except httpx.TimeoutException:
            return None, "timeout"
        except Exception as e:
            logger.error(f"[{model}] erro inesperado: {e}")
            return None, "error"

    def _call_api(self, text_content: str) -> str | None:
        """
        Traduz um chunk seguindo a cadeia de fallback:
          1) Gemini (chave 1) → 2) Gemini (chave 2) → 3) OpenRouter pago → 4) OpenRouter grátis.
        Pula rápido em rate limit/erro; sinaliza se TODA a cadeia ficou rate-limited.
        """
        total = 0
        rate_limited = 0

        # 1 e 2 — Gemini (chaves de projetos diferentes = cotas independentes)
        for i, key in enumerate(self.gemini_keys, 1):
            if key in self._gemini_dead:
                continue
            total += 1
            content, reason = self._request_gemini(key, text_content)
            if content is not None:
                logger.info(f"Chunk traduzido via: Gemini #{i} ({self.gemini_model})")
                return content
            if reason == "no_credit":
                logger.warning(f"Gemini #{i}: chave inválida/sem acesso — desativando nesta sessão.")
                self._gemini_dead.add(key)
            elif reason in ("rate_limited", "timeout"):
                rate_limited += 1
                logger.warning(f"Gemini #{i}: {reason} — tentando o próximo provedor.")

        # 3 — OpenRouter pago (DeepSeek)
        if self.api_key and self.paid_available:
            total += 1
            content, reason = self._request_model(self.model, text_content)
            if content is not None:
                logger.info(f"Chunk traduzido via: {self.model} (OpenRouter pago)")
                return content
            if reason == "no_credit":
                logger.warning("OpenRouter pago sem créditos (402) — usando apenas gratuitos nesta sessão.")
                self.paid_available = False
            elif reason in ("rate_limited", "timeout"):
                rate_limited += 1

        # 4 — OpenRouter grátis (descoberta dinâmica)
        if self.api_key:
            free = [m for m in self._get_free_models() if m not in self.dead_models][:self.max_free]
            for model in free:
                total += 1
                content, reason = self._request_model(model, text_content)
                if content is not None:
                    logger.info(f"Chunk traduzido via: {model} (OpenRouter grátis)")
                    return content
                if reason == "not_found":
                    logger.warning(f"[{model}] indisponível (404) — removido desta sessão.")
                    self.dead_models.add(model)
                elif reason in ("rate_limited", "timeout"):
                    rate_limited += 1
                    logger.warning(f"[{model}] {reason} — tentando o próximo modelo.")

        self._last_all_rate_limited = (total > 0 and rate_limited == total)
        logger.error("Nenhum provedor de IA traduziu este chunk.")
        return None

    # ------------------------------------------------------------------ #
    # Helpers de parsing SRT                                               #
    # ------------------------------------------------------------------ #

    def parse_timestamp(self, ts: str) -> float:
        h, m, s_ms = ts.split(":")
        s, ms = s_ms.split(",")
        return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000.0

    def extract_timestamps(self, srt_content: str):
        pattern = re.compile(r"(\d+)\s*\n(\d{2}:\d{2}:\d{2},\d{3}) --> (\d{2}:\d{2}:\d{2},\d{3})")
        timestamps = []
        for index, start_str, end_str in pattern.findall(srt_content):
            timestamps.append({
                "index": index,
                "timestamp_line": f"{start_str} --> {end_str}",
                "start": self.parse_timestamp(start_str),
                "end": self.parse_timestamp(end_str),
            })
        return timestamps

    def split_content_by_time(self, content: str, chunk_duration: int = CHUNK_DURATION):
        timestamps = self.extract_timestamps(content)
        if not timestamps:
            return []

        blocks = re.split(r"\n\s*\n", content.strip())
        text_map = {}
        for block in blocks:
            parts = block.strip().split("\n")
            if len(parts) >= 3:
                text_map[parts[0].strip()] = block

        chunks, current_chunk = [], []
        chunk_start_time = timestamps[0]["start"]

        for ts in timestamps:
            if ts["start"] - chunk_start_time > chunk_duration:
                if current_chunk:
                    chunks.append(current_chunk)
                current_chunk = []
                chunk_start_time = ts["start"]
            if ts["index"] in text_map:
                current_chunk.append(text_map[ts["index"]])

        if current_chunk:
            chunks.append(current_chunk)

        return ["\n\n".join(c) for c in chunks]

    def parse_translation(self, raw: str) -> dict:
        """
        Parseia o SRT traduzido retornado pela IA.
        Usa split por linha em branco para ser robusto contra variações de formato.
        Retorna { "1": "texto traduzido", "2": "texto traduzido", ... }
        """
        result = {}
        # Remove possíveis marcadores de código (```srt ... ```)
        clean = re.sub(r"```[a-zA-Z]*\n?", "", raw).strip()
        blocks = re.split(r"\n\s*\n", clean)

        for block in blocks:
            lines = block.strip().splitlines()
            if not lines:
                continue
            # Primeira linha deve ser o índice numérico
            idx_line = lines[0].strip()
            if not idx_line.isdigit():
                continue
            # Segunda linha deve ser o timestamp (opcional, mas pulamos)
            if len(lines) < 3:
                continue
            # O texto começa na linha 3 em diante (após index + timestamp)
            text_lines = lines[2:]
            result[idx_line] = "\n".join(text_lines).strip()

        return result

    def merge_and_save(self, original_srt_path: str, translated_map: dict, output_path: str) -> bool:
        try:
            with open(original_srt_path, "r", encoding="utf-8") as f:
                original_content = f.read()

            pattern = re.compile(r"(\d+)\s*\n(\d{2}:\d{2}:\d{2},\d{3} --> \d{2}:\d{2}:\d{2},\d{3})")
            matches = pattern.findall(original_content)

            if len(matches) != len(translated_map):
                logger.warning(
                    f"Discrepância de linhas: original={len(matches)}, traduzido={len(translated_map)}"
                )

            final_srt = [f"{idx}\n{tc}\n{translated_map.get(idx, '')}\n" for idx, tc in matches]
            return save_subtitle("\n".join(final_srt), output_path)

        except Exception as e:
            logger.error(f"Erro ao fazer merge das legendas: {e}")
            return False

    # ------------------------------------------------------------------ #
    # Ponto de entrada principal                                           #
    # ------------------------------------------------------------------ #

    def process(self, source_srt_path: str, output_path: str, guard_path: str | None = None) -> bool:
        """Chunk → Traduz via OpenRouter → Merge → Salva.

        Serializado por lock: evita que o scanner e o JobProcessor traduzam ao mesmo
        tempo e dobrem o consumo do rate limit gratuito.
        guard_path: se informado e o arquivo sumir durante a tradução (ex.: rejeitado/
        deletado pelo Arr), aborta — evita gastar cota traduzindo um arquivo morto.
        """
        logger.info(f"Iniciando tradução: {source_srt_path}")
        with self._lock:
            return self._process_locked(source_srt_path, output_path, guard_path)

    def _process_locked(self, source_srt_path: str, output_path: str, guard_path: str | None = None) -> bool:
        try:
            with open(source_srt_path, "r", encoding="utf-8") as f:
                content = f.read()

            chunks = self.split_content_by_time(content)
            logger.info(f"Conteúdo dividido em {len(chunks)} chunk(s) de ~15min.")

            full_map: dict = {}
            ok_chunks = 0
            self._last_all_rate_limited = False

            for i, chunk in enumerate(chunks, 1):
                if guard_path and not os.path.exists(guard_path):
                    logger.warning(f"Mídia removida durante a tradução ({os.path.basename(guard_path)}) — abortando.")
                    return False
                logger.info(f"Traduzindo chunk {i}/{len(chunks)}...")
                raw = self._call_api(chunk)
                if raw:
                    full_map.update(self.parse_translation(raw))
                    ok_chunks += 1
                else:
                    logger.error(f"Chunk {i} falhou.")
                    # Se a cadeia inteira está rate-limited (conta gratuita esgotada),
                    # não adianta insistir nos demais chunks — aborta e tenta depois.
                    if getattr(self, "_last_all_rate_limited", False):
                        logger.error("Conta gratuita esgotada (rate limit) — abortando os chunks restantes.")
                        break

            # Verifica se a tradução por IA realmente produziu conteúdo.
            # Sem isto, uma falha total (ex.: sem créditos) salvaria um SRT só com
            # linhas em branco e seria contabilizada como "sucesso".
            if not full_map:
                logger.error(
                    "Tradução por IA NÃO foi realizada: nenhum chunk traduzido "
                    "(verifique créditos do OpenRouter e disponibilidade dos modelos gratuitos)."
                )
                return False
            if ok_chunks < len(chunks):
                logger.warning(f"Tradução parcial: {ok_chunks}/{len(chunks)} chunks traduzidos.")
            else:
                logger.info(f"Tradução completa: {ok_chunks}/{len(chunks)} chunks.")

            return self.merge_and_save(source_srt_path, full_map, output_path)

        except Exception as e:
            logger.error(f"Processo de tradução falhou: {e}")
            return False
