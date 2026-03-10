import os
import time
import httpx
import logging
import re
from .utils import save_subtitle

logger = logging.getLogger(__name__)

OPENROUTER_API_URL = "https://openrouter.ai/api/v1/chat/completions"
CHUNK_DURATION = 900  # 15 minutos por chunk


class Translator:
    def __init__(self):
        self.api_key = os.environ.get("OPENROUTER_API_KEY", "")
        self.model = os.environ.get("OPENROUTER_MODEL", "deepseek/deepseek-v3-0324")

        if not self.api_key:
            raise ValueError("OPENROUTER_API_KEY não encontrada nas variáveis de ambiente.")

        logger.info(f"Translator inicializado com modelo: {self.model}")

    def _call_api(self, text_content: str) -> str | None:
        """Chama a API do OpenRouter com retry simples (3 tentativas)."""
        prompt = (
            "Você é um tradutor profissional de legendas (SRT). "
            "Traduza o conteúdo abaixo para Português do Brasil (pt-br). "
            "Adapte gírias e expressões para o contexto brasileiro. "
            "NÃO altere a quantidade de linhas de diálogo. "
            "Retorne APENAS o texto traduzido no formato SRT, sem explicações."
        )

        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://github.com/legendarr",
            "X-Title": "Legendarr",
        }

        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": prompt},
                {"role": "user", "content": text_content},
            ],
        }

        for attempt in range(1, 4):
            try:
                logger.info(f"[Tentativa {attempt}/3] Enviando chunk para OpenRouter ({self.model})...")
                with httpx.Client(timeout=120.0) as client:
                    response = client.post(OPENROUTER_API_URL, headers=headers, json=payload)

                if response.status_code == 200:
                    data = response.json()
                    return data["choices"][0]["message"]["content"]
                elif response.status_code == 429:
                    wait = 30 * attempt
                    logger.warning(f"Rate limit (429). Aguardando {wait}s...")
                    time.sleep(wait)
                else:
                    logger.error(f"Erro HTTP {response.status_code}: {response.text[:300]}")
                    time.sleep(5 * attempt)

            except httpx.TimeoutException:
                logger.warning(f"Timeout na tentativa {attempt}. Aguardando 10s...")
                time.sleep(10)
            except Exception as e:
                logger.error(f"Erro inesperado na tentativa {attempt}: {e}")
                time.sleep(5)

        logger.error("Todas as 3 tentativas falharam.")
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

            for i, chunk in enumerate(chunks, 1):
                logger.info(f"Traduzindo chunk {i}/{len(chunks)}...")
                raw = self._call_api(chunk)
                if raw:
                    full_map.update(self.parse_translation(raw))
                else:
                    logger.error(f"Chunk {i} falhou — será ignorado.")

            return self.merge_and_save(source_srt_path, full_map, output_path)

        except Exception as e:
            logger.error(f"Processo de tradução falhou: {e}")
            return False
