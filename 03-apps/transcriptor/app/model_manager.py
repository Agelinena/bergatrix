import gc
import logging
import torch
import os
from faster_whisper import WhisperModel

logger = logging.getLogger(__name__)

VALID_MODELS = ["small", "medium", "large-v3"]

# VRAM estimada por modelo (usando int8)
MODEL_VRAM_GB = {
    "small": 1.0,
    "medium": 2.5,
    "large-v3": 6.0,
}

# Mapeamento para as pastas locais montadas via volume no Docker
MODEL_PATHS = {
    "small": "/app/models/whisper-small",
    "medium": "/app/models/whisper-medium",
    "large-v3": "/app/models/whisper-large-v3",
}

class ModelManager:
    """Singleton que gerencia os modelos do faster-whisper na VRAM da GPU.

    Garante que apenas um modelo esteja carregado por vez para respeitar o 
    limite de VRAM do servidor.
    """

    _instance = None
    _current_model_name: str | None = None
    _model: WhisperModel | None = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    def load(self, model_name: str) -> WhisperModel:
        """Carrega o modelo solicitado, descarregando o anterior se necessário."""

        if model_name not in VALID_MODELS:
            raise ValueError(
                f"Modelo inválido: '{model_name}'. Opções: {VALID_MODELS}"
            )

        # Se já estiver carregado, retorna imediatamente
        if self._current_model_name == model_name and self._model is not None:
            logger.info(f"MODEL MANAGER: Modelo '{model_name}' já está carregado. Reutilizando.")
            return self._model

        # Descarrega o modelo anterior para liberar VRAM
        if self._model is not None:
            logger.info(
                f"MODEL MANAGER: Descarregando modelo '{self._current_model_name}' para liberar VRAM..."
            )
            del self._model
            self._model = None
            self._current_model_name = None
            gc.collect()
            torch.cuda.empty_cache()
            logger.info("MODEL MANAGER: VRAM liberada.")

        # Configuração de dispositivo e precisão
        device = "cuda" if torch.cuda.is_available() else "cpu"

        # int8 é obrigatório para respeitar o limite de 6GB da GTX 1060
        # Prioriza a variável de ambiente, mas força int8 como padrão seguro
        compute_type = os.getenv("COMPUTE_TYPE", "int8")
        if device == "cpu":
            compute_type = "int8"

        model_path = MODEL_PATHS.get(model_name)

        logger.info(
            f"MODEL MANAGER: Carregando modelo '{model_name}' de '{model_path}' "
            f"no dispositivo '{device}' (compute_type={compute_type})..."
        )

        try:
            # Carrega o modelo com restrições explícitas de threads para economizar RAM (Garante que OpenMP não multiplicará buffers em todos os núcleos)
            self._model = WhisperModel(
                model_path,
                device=device,
                compute_type=compute_type,
                cpu_threads=2,
                num_workers=1,
                local_files_only=True  # Garante que não tentará baixar nada
            )
            self._current_model_name = model_name
            logger.info(f"MODEL MANAGER: Modelo '{model_name}' carregado com sucesso.")
            return self._model

        except RuntimeError as e:
            if "out of memory" in str(e).lower() or "cuda" in str(e).lower():
                gc.collect()
                torch.cuda.empty_cache()
                raise RuntimeError(
                    f"Erro de GPU/VRAM ao carregar o modelo '{model_name}'. "
                    f"Requer aprox. {MODEL_VRAM_GB.get(model_name, '?')}GB. "
                    f"Detalhes: {str(e)}"
                ) from e
            raise

    @property
    def current_model_name(self) -> str | None:
        return self._current_model_name

# Instância singleton global
model_manager = ModelManager()
