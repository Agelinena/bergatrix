import os
import time
import httpx
import logging
import re
from .utils import save_subtitle

logger = logging.getLogger(__name__)

OPENROUTER_API_URL = "https://openrouter.ai/api/v1/chat/completions"
CHUNK_DURATION = 900  # 15 minutos por chunk

# Modelos GRATUITOS de fallback, priorizando os melhores para PT-BR.
# Usados quando o modelo pago fica sem créditos (HTTP 402).
# O deepseek :free é o mesmo modelo do pago — apenas com rate limit.
DEFAULT_FREE_MODELS = [
    "deepseek/deepseek-chat-v3-0324:free",
    "meta-llama/llama-3.3-70b-instruct:free",
    "qwen/qwen-2.5-72b-instruct:free",
    "google/gemini-2.0-flash-exp:free",
]

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

        # Modelos gratuitos de fallback (CSV em OPENROUTER_FREE_MODELS sobrescreve o default)
        free_env = os.environ.get("OPENROUTER_FREE_MODELS", "").strip()
        self.free_models = (
            [m.strip() for m in free_env.split(",") if m.strip()] if free_env
            else list(DEFAULT_FREE_MODELS)
        )
        # Quantos modelos gratuitos tentar antes de desistir de um chunk
        self.max_free = int(os.environ.get("MAX_FREE_FALLBACKS", "3"))
        # Ao detectar 402 no pago, paramos de tentá-lo no resto da sessão (evita 402 a cada chunk)
        self.paid_available = True

        if not self.api_key:
            raise ValueError("OPENROUTER_API_KEY não encontrada nas variáveis de ambiente.")

        logger.info(
            f"Translator inicializado. Pago: {self.model} | "
            f"Fallback gratuito (até {self.max_free}): {self.free_models[:self.max_free]}"
        )

    def _request_model(self, model: str, text_content: str, retries: int = 2) -> tuple[str | None, str]:
        """
        Tenta UM modelo. Retorna (conteudo, motivo).
        motivo ∈ {"ok", "no_credit", "rate_limited", "not_found", "error"}.
        Faz retry interno para 429 (rate limit) e timeout — relevante p/ modelos free.
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

        for attempt in range(1, retries + 1):
            try:
                with httpx.Client(timeout=180.0) as client:
                    response = client.post(OPENROUTER_API_URL, headers=headers, json=payload)

                if response.status_code == 200:
                    data = response.json()
                    choices = data.get("choices") or []
                    if not choices:
                        # Alguns modelos free devolvem erro dentro de um corpo 200
                        logger.warning(f"[{model}] 200 sem 'choices': {str(data)[:200]}")
                        return None, "error"
                    content = choices[0].get("message", {}).get("content", "")
                    if not content or not content.strip():
                        return None, "error"
                    return content, "ok"

                if response.status_code in (401, 402):
                    return None, "no_credit"
                if response.status_code == 404:
                    logger.warning(f"[{model}] modelo não encontrado (404) — pulando.")
                    return None, "not_found"
                if response.status_code == 429:
                    wait = 20 * attempt
                    logger.warning(f"[{model}] rate limit (429). Aguardando {wait}s...")
                    time.sleep(wait)
                    continue

                logger.error(f"[{model}] HTTP {response.status_code}: {response.text[:200]}")
                time.sleep(3 * attempt)

            except httpx.TimeoutException:
                logger.warning(f"[{model}] timeout (tentativa {attempt}/{retries}).")
                time.sleep(5)
            except Exception as e:
                logger.error(f"[{model}] erro inesperado: {e}")
                time.sleep(3)

        return None, "rate_limited"

    def _call_api(self, text_content: str) -> str | None:
        """
        Traduz um chunk tentando, em ordem: modelo pago → modelos gratuitos.
        Em 402 no pago, alterna para os gratuitos pelo resto da sessão.
        """
        chain = []
        if self.paid_available:
            chain.append(self.model)
        chain += self.free_models[:self.max_free]

        for model in chain:
            content, reason = self._request_model(model, text_content)
            if content is not None:
                logger.info(f"Chunk traduzido via: {model}")
                return content

            if reason == "no_credit" and model == self.model:
                logger.warning(
                    "Modelo pago sem créditos (HTTP 402) — alternando para modelos gratuitos nesta sessão."
                )
                self.paid_available = False
            # tenta o próximo modelo da cadeia

        logger.error("Todos os modelos (pago + gratuitos) falharam para este chunk.")
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

    def process(self, source_srt_path: str, output_path: str) -> bool:
        """Chunk → Traduz via OpenRouter → Merge → Salva."""
        logger.info(f"Iniciando tradução: {source_srt_path}")

        try:
            with open(source_srt_path, "r", encoding="utf-8") as f:
                content = f.read()

            chunks = self.split_content_by_time(content)
            logger.info(f"Conteúdo dividido em {len(chunks)} chunk(s) de ~15min.")

            full_map: dict = {}
            ok_chunks = 0

            for i, chunk in enumerate(chunks, 1):
                logger.info(f"Traduzindo chunk {i}/{len(chunks)}...")
                raw = self._call_api(chunk)
                if raw:
                    full_map.update(self.parse_translation(raw))
                    ok_chunks += 1
                else:
                    logger.error(f"Chunk {i} falhou.")

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
