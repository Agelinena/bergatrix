import os
import threading
import httpx
import logging
import re
from .utils import save_subtitle

logger = logging.getLogger(__name__)

CHUNK_DURATION = 900  # 15 min por chunk (janela temporal de divisão)

# System prompt do TRADUTOR. A entrada vai numerada ([N] texto) para garantir a
# correspondência 1:1 com os blocos originais e poder revisar o que faltou.
TRANSLATOR_SYSTEM_BASE = (
    "Você é um tradutor profissional de legendas para Português do Brasil (PT-BR).\n"
    "A entrada são linhas no formato: [N] texto original.\n"
    "Regras de saída (OBRIGATÓRIAS):\n"
    "1. Responda APENAS com as linhas traduzidas, no MESMO formato: [N] texto.\n"
    "2. Use EXATAMENTE os mesmos números [N], na mesma ordem, sem pular nem juntar entradas.\n"
    "3. Uma entrada por número [N]. Não escreva comentários nem nada fora desse formato.\n"
    "4. Traduza com fidelidade ao sentido e ao REGISTRO de cada fala; preserve nomes próprios.\n"
)

# O briefing do diretor entra como guia — com trava explícita contra exagero de gíria.
DIRECTOR_GUIDE_PREFIX = (
    "DIREÇÃO DE TRADUÇÃO (guia de tom e de consistência de termos — é orientação, NÃO "
    "licença para inserir gírias onde o original não tem; respeite o registro de cada fala):\n"
)

# System prompt do DIRETOR — produz um briefing curto e conservador.
DIRECTOR_SYSTEM = (
    "Você é um DIRETOR DE LOCALIZAÇÃO. A partir de uma AMOSTRA de falas de um filme ou série, "
    "escreva um briefing CURTO (no máximo ~120 palavras) para orientar o tradutor de PT-BR. Inclua:\n"
    "- gênero e tom geral da obra;\n"
    "- registro de linguagem (formal ↔ coloquial) e o nível de gíria adequado (baixo, médio ou alto);\n"
    "- nomes próprios ou termos que devem ser MANTIDOS sem tradução;\n"
    "- um glossário de no MÁXIMO 6 termos/expressões recorrentes com a tradução PT-BR recomendada.\n"
    "Seja CONSERVADOR: priorize fidelidade e naturalidade; não exagere em gírias. "
    "Responda em português, em tópicos curtos."
)


class Translator:
    """
    Tradução de legendas 100% LOCAL via Ollama, com dois papéis:

      • DIRETOR (DIRECTOR_MODEL): lê uma AMOSTRA do filme e gera um briefing de
        tom/registro/termos. Roda 1x por legenda. Pode ser desligado.
      • TRADUTOR (TRANSLATOR_MODEL): traduz os blocos em PT-BR seguindo o briefing.

    A tradução é feita em formato numerado ([N] texto) para garantir correspondência
    1:1 com os blocos originais. Cada chunk é revisado: os blocos que não vieram
    traduzidos são reenviados (até BLOCK_RETRANSLATE_ROUNDS vezes) antes da montagem
    final, que reaproveita os timestamps originais (formato e sincronia garantidos).
    """

    def __init__(self):
        self.base_url = os.environ.get("LOCAL_AI_URL", "http://ollama:11434").rstrip("/")
        self.translator_model = os.environ.get("TRANSLATOR_MODEL", "translategemma:4b")
        self.director_model = os.environ.get("DIRECTOR_MODEL", "qwen2.5:7b")
        self.director_enabled = os.environ.get("DIRECTOR_ENABLED", "true").lower() == "true"
        self.director_sample_lines = int(os.environ.get("DIRECTOR_SAMPLE_LINES", "180"))
        self.num_ctx = int(os.environ.get("OLLAMA_NUM_CTX", "8192"))
        self.timeout = float(os.environ.get("OLLAMA_TIMEOUT", "600"))
        self.translator_temp = float(os.environ.get("TRANSLATOR_TEMPERATURE", "0.2"))
        self.director_temp = float(os.environ.get("DIRECTOR_TEMPERATURE", "0.5"))
        self.block_rounds = int(os.environ.get("BLOCK_RETRANSLATE_ROUNDS", "3"))
        self.block_batch = int(os.environ.get("TRANSLATE_BATCH_BLOCKS", "60"))
        self.min_block_coverage = float(os.environ.get("TRANSLATION_MIN_BLOCK_COVERAGE", "0.90"))
        self._lock = threading.Lock()  # serializa traduções (scanner + jobs) — 1 modelo por vez na GPU

        logger.info(
            f"Translator (local/Ollama @ {self.base_url}) — "
            f"diretor: {self.director_model if self.director_enabled else 'OFF'} | "
            f"tradutor: {self.translator_model} | ctx={self.num_ctx}"
        )

    # ------------------------------------------------------------------ #
    # Cliente Ollama                                                       #
    # ------------------------------------------------------------------ #
    def _ollama_chat(self, model: str, system: str, user: str, temperature: float) -> str | None:
        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "stream": False,
            "options": {"temperature": temperature, "num_ctx": self.num_ctx},
        }
        try:
            with httpx.Client(timeout=self.timeout) as c:
                r = c.post(f"{self.base_url}/api/chat", json=payload)
            if r.status_code == 200:
                content = (r.json().get("message") or {}).get("content", "")
                return content.strip() or None
            logger.error(f"[ollama:{model}] HTTP {r.status_code}: {r.text[:200]}")
            return None
        except httpx.TimeoutException:
            logger.error(f"[ollama:{model}] timeout após {self.timeout:.0f}s (modelo carregando/sobrecarregado?).")
            return None
        except Exception as e:
            logger.error(f"[ollama:{model}] erro de conexão: {e}")
            return None

    # ------------------------------------------------------------------ #
    # Parsing / divisão de SRT                                             #
    # ------------------------------------------------------------------ #
    def parse_timestamp(self, ts: str) -> float:
        h, m, s_ms = ts.split(":")
        s, ms = s_ms.split(",")
        return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000.0

    def extract_timestamps(self, srt_content: str):
        pattern = re.compile(r"(\d+)\s*\n(\d{2}:\d{2}:\d{2},\d{3}) --> (\d{2}:\d{2}:\d{2},\d{3})")
        out = []
        for index, start_str, _end in pattern.findall(srt_content):
            out.append({"index": index, "start": self.parse_timestamp(start_str)})
        return out

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
        chunks, current = [], []
        start0 = timestamps[0]["start"]
        for ts in timestamps:
            if ts["start"] - start0 > chunk_duration:
                if current:
                    chunks.append(current)
                current = []
                start0 = ts["start"]
            if ts["index"] in text_map:
                current.append(text_map[ts["index"]])
        if current:
            chunks.append(current)
        return ["\n\n".join(c) for c in chunks]

    @staticmethod
    def _blocks_of_chunk(srt_text: str):
        """Extrai [(index, texto)] de um trecho SRT, juntando as linhas de texto do bloco."""
        items = []
        for block in re.split(r"\n\s*\n", srt_text.strip()):
            lines = block.strip().splitlines()
            if len(lines) < 3:
                continue
            idx = lines[0].strip()
            if not idx.isdigit():
                continue
            text = " ".join(l.strip() for l in lines[2:] if l.strip())
            if text:
                items.append((idx, text))
        return items

    def _parse_numbered(self, raw: str, batch_items: list) -> dict:
        """
        Parseia a resposta no formato '[N] texto'. Se o modelo ignorar os marcadores
        mas devolver uma linha por bloco (na ordem), faz um fallback POSICIONAL.
        """
        clean = re.sub(r"```[a-zA-Z]*\n?", "", raw).strip()
        result = {}
        for m in re.finditer(r"\[(\d+)\]\s*(.*?)(?=\n\s*\[\d+\]|\Z)", clean, re.S):
            txt = re.sub(r"\s*\n\s*", " ", m.group(2)).strip()
            if txt:
                result[m.group(1)] = txt
        # Fallback posicional: modelo respondeu sem [N], mas com 1 linha por bloco.
        if len(result) < len(batch_items) * 0.5:
            lines = [re.sub(r"^\s*\[?\d+\]?[\.\):\-]?\s*", "", l).strip()
                     for l in clean.splitlines() if l.strip()]
            if len(lines) == len(batch_items):
                result = {idx: lines[i] for i, (idx, _) in enumerate(batch_items)}
                logger.info("  (parse posicional: resposta sem [N], mapeada por ordem)")
        return result

    # ------------------------------------------------------------------ #
    # Diretor (contexto) + Tradutor                                        #
    # ------------------------------------------------------------------ #
    def _sample_for_director(self, content: str) -> str:
        texts = [t for _, t in self._blocks_of_chunk(content)]
        n = self.director_sample_lines
        if n > 0 and len(texts) > n:
            step = len(texts) / n
            texts = [texts[int(i * step)] for i in range(n)]
        return "\n".join(texts)

    def _build_brief(self, content: str) -> str:
        if not self.director_enabled:
            return ""
        sample = self._sample_for_director(content)
        if not sample.strip():
            return ""
        logger.info(f"Diretor ({self.director_model}): analisando contexto/tom do filme...")
        brief = self._ollama_chat(self.director_model, DIRECTOR_SYSTEM, sample, self.director_temp)
        if brief:
            logger.info("Briefing de tradução gerado pelo diretor.")
            return brief[:1500]
        logger.warning("Diretor indisponível — seguindo a tradução SEM briefing de contexto.")
        return ""

    def _translate_blocks(self, items: list, system: str) -> dict:
        """Traduz uma lista [(idx, texto)] em lotes de block_batch; retorna {idx: traducao}."""
        result = {}
        for i in range(0, len(items), self.block_batch):
            batch = items[i:i + self.block_batch]
            user = "\n".join(f"[{idx}] {text}" for idx, text in batch)
            raw = self._ollama_chat(self.translator_model, system, user, self.translator_temp)
            if raw:
                result.update(self._parse_numbered(raw, batch))
        return result

    def process(self, source_srt_path: str, output_path: str, guard_path: str | None = None) -> bool:
        logger.info(f"Iniciando tradução (local): {source_srt_path}")
        with self._lock:
            return self._process_locked(source_srt_path, output_path, guard_path)

    def _process_locked(self, source_srt_path: str, output_path: str, guard_path: str | None = None) -> bool:
        try:
            with open(source_srt_path, "r", encoding="utf-8") as f:
                content = f.read()

            chunks = self.split_content_by_time(content)
            if not chunks:
                logger.error("Sem blocos de legenda para traduzir.")
                return False
            logger.info(f"Conteúdo dividido em {len(chunks)} chunk(s) de ~15min.")

            # Fase 1 — Diretor: briefing de contexto (1x por legenda)
            brief = self._build_brief(content)
            system = TRANSLATOR_SYSTEM_BASE
            if brief:
                system = TRANSLATOR_SYSTEM_BASE + "\n" + DIRECTOR_GUIDE_PREFIX + brief

            # Fase 2 — Tradutor: chunk a chunk, com revisão por bloco
            full_map: dict = {}
            total_blocks = translated_blocks = 0
            for i, chunk in enumerate(chunks, 1):
                if guard_path and not os.path.exists(guard_path):
                    logger.warning("Mídia removida durante a tradução — abortando.")
                    return False
                items = self._blocks_of_chunk(chunk)
                if not items:
                    continue
                total_blocks += len(items)
                logger.info(f"Traduzindo chunk {i}/{len(chunks)} ({len(items)} blocos)...")

                trad: dict = {}
                pending = items
                for rnd in range(1, self.block_rounds + 1):
                    got = self._translate_blocks(pending, system)
                    for k, v in got.items():
                        if v.strip():
                            trad[k] = v
                    pending = [(idx, t) for idx, t in items if not trad.get(idx, "").strip()]
                    if not pending:
                        break
                    if guard_path and not os.path.exists(guard_path):
                        return False
                    logger.info(
                        f"  Revisão: {len(pending)} bloco(s) sem tradução — "
                        f"retraduzindo (rodada {rnd}/{self.block_rounds})..."
                    )

                translated_blocks += len(items) - len(pending)
                # Resíduo irrecuperável: mantém o texto original p/ não dessincronizar a legenda.
                if pending:
                    logger.warning(
                        f"  {len(pending)} bloco(s) sem tradução após {self.block_rounds} rodadas "
                        f"— mantendo o texto original nesses blocos."
                    )
                    for idx, t in pending:
                        trad.setdefault(idx, t)
                full_map.update(trad)

            if not full_map:
                logger.error("Tradução local não produziu conteúdo (Ollama fora do ar?).")
                return False

            coverage = (translated_blocks / total_blocks) if total_blocks else 0.0
            if coverage < self.min_block_coverage:
                logger.warning(
                    f"Tradução incompleta: só {translated_blocks}/{total_blocks} blocos "
                    f"({coverage * 100:.0f}%) — DESCARTADA, será refeita na próxima revisita."
                )
                return False

            logger.info(
                f"Tradução completa: {translated_blocks}/{total_blocks} blocos "
                f"({coverage * 100:.0f}%)."
            )
            return self.merge_and_save(source_srt_path, full_map, output_path)

        except Exception as e:
            logger.error(f"Processo de tradução falhou: {e}")
            return False

    def merge_and_save(self, original_srt_path: str, translated_map: dict, output_path: str) -> bool:
        """Remonta o SRT final usando os timestamps ORIGINAIS, casando por índice."""
        try:
            with open(original_srt_path, "r", encoding="utf-8") as f:
                original_content = f.read()
            pattern = re.compile(r"(\d+)\s*\n(\d{2}:\d{2}:\d{2},\d{3} --> \d{2}:\d{2}:\d{2},\d{3})")
            matches = pattern.findall(original_content)
            final_srt = [f"{idx}\n{tc}\n{translated_map.get(idx, '')}\n" for idx, tc in matches]
            return save_subtitle("\n".join(final_srt), output_path)
        except Exception as e:
            logger.error(f"Erro ao fazer merge das legendas: {e}")
            return False
