import gc
import logging
import torch
from faster_whisper import WhisperModel

logger = logging.getLogger(__name__)

VALID_MODELS = ["small", "distil-large-v3", "large-v3"]

# Approximate VRAM requirement per model in GB (float16)
MODEL_VRAM_GB = {
    "small": 1.0,
    "distil-large-v3": 3.0,
    "large-v3": 6.0,
}


class ModelManager:
    """Singleton that manages a single faster-whisper model in GPU VRAM.

    Handles safe unloading of the previous model before loading the next one,
    ensuring the 6GB VRAM budget is never exceeded by two concurrent models.
    """

    _instance = None
    _current_model_name: str | None = None
    _model: WhisperModel | None = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    def load(self, model_name: str) -> WhisperModel:
        """Load the requested model, unloading the current one if different."""

        if model_name not in VALID_MODELS:
            raise ValueError(
                f"Modelo inválido: '{model_name}'. Opções: {VALID_MODELS}"
            )

        # Already loaded — return immediately
        if self._current_model_name == model_name and self._model is not None:
            logger.info(f"MODEL MANAGER: Modelo '{model_name}' já está carregado. Reutilizando.")
            return self._model

        # Unload previous model to free VRAM
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

        # Load new model
        device = "cuda" if torch.cuda.is_available() else "cpu"
        compute_type = "float16" if device == "cuda" else "int8"

        logger.info(
            f"MODEL MANAGER: Carregando modelo '{model_name}' no dispositivo '{device}' "
            f"(compute_type={compute_type})..."
        )

        try:
            self._model = WhisperModel(model_name, device=device, compute_type=compute_type)
            self._current_model_name = model_name
            logger.info(f"MODEL MANAGER: Modelo '{model_name}' carregado com sucesso.")
            return self._model
        except RuntimeError as e:
            if "out of memory" in str(e).lower() or "cuda" in str(e).lower():
                gc.collect()
                torch.cuda.empty_cache()
                raise RuntimeError(
                    f"VRAM insuficiente para carregar o modelo '{model_name}'. "
                    f"Requer aprox. {MODEL_VRAM_GB.get(model_name, '?')}GB. "
                    f"Tente o modelo 'small'."
                ) from e
            raise

    @property
    def current_model_name(self) -> str | None:
        return self._current_model_name


# Global singleton instance
model_manager = ModelManager()
