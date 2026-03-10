"""
LiteLLM Free Model Sync — Sidecar
Sincroniza dinamicamente todos os modelos :free da OpenRouter com o LiteLLM Proxy via API REST.

Lógica por ciclo:
  1. Fetch OpenRouter /models  → filtra modelos com pricing gratuito
  2. Fetch LiteLLM /model/info → lê modelos com prefixo "or-free/" (gerenciados por este script)
  3. Diff add/remove
  4. POST /model/new  (novos)
  5. POST /model/delete (removidos)
  6. Sleep SYNC_INTERVAL segundos
"""

import os
import time
import logging
import requests

# ─── Configuração ─────────────────────────────────────────────────────────────
LITELLM_URL     = os.environ.get("LITELLM_URL", "http://litellm:4000")
MASTER_KEY      = os.environ["LITELLM_MASTER_KEY"]
OPENROUTER_KEY  = os.environ["OPENROUTER_API_KEY"]
SYNC_INTERVAL   = int(os.environ.get("SYNC_INTERVAL", "3600"))

OR_MODELS_URL   = "https://openrouter.ai/api/v1/models"

# Prefixo usado em model_name para identificar modelos gerenciados por este sidecar
MANAGED_PREFIX  = "or-free/"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("free-model-sync")

# ─── Helpers ──────────────────────────────────────────────────────────────────

def litellm_headers() -> dict:
    return {
        "Authorization": f"Bearer {MASTER_KEY}",
        "Content-Type": "application/json",
    }


def is_free(model: dict) -> bool:
    """
    Detecção dupla:
      (a) id termina com ':free'  — convenção explícita da OpenRouter
      (b) pricing.prompt == "0" E pricing.completion == "0"  — safety net
    """
    model_id = model.get("id", "")
    if model_id.endswith(":free"):
        return True
    pricing = model.get("pricing", {})
    try:
        return float(pricing.get("prompt", "1")) == 0 and \
               float(pricing.get("completion", "1")) == 0
    except (TypeError, ValueError):
        return False


def fetch_openrouter_free() -> dict[str, str]:
    """
    Retorna {model_name_no_proxy: openrouter_model_id}
    model_name_no_proxy  → "or-free/google/gemini-2.0-flash-exp"
    openrouter_model_id  → "google/gemini-2.0-flash-exp:free"
    """
    resp = requests.get(OR_MODELS_URL, timeout=30)
    resp.raise_for_status()
    data = resp.json().get("data", [])

    result: dict[str, str] = {}
    for m in data:
        if not is_free(m):
            continue
        model_id: str = m["id"]
        # Normaliza model_name: remove ":free" do sufixo para evitar : no nome
        clean_name = model_id.replace(":free", "").strip("/")
        proxy_name = f"{MANAGED_PREFIX}{clean_name}"
        result[proxy_name] = model_id

    log.info(f"OpenRouter: {len(result)} modelos free encontrados.")
    return result


def fetch_litellm_managed() -> dict[str, str]:
    """
    Retorna {model_name: db_model_id} para modelos gerenciados (prefixo or-free/).
    db_model_id é o campo 'model_id' retornado pela API do LiteLLM, necessário para deletar.
    """
    resp = requests.get(
        f"{LITELLM_URL}/model/info",
        headers=litellm_headers(),
        timeout=15,
    )
    resp.raise_for_status()
    data = resp.json().get("data", [])

    result: dict[str, str] = {}
    for entry in data:
        name = entry.get("model_name", "")
        if name.startswith(MANAGED_PREFIX):
            # model_id é retornado como entry["model_info"]["id"] ou entry.get("model_id")
            db_id = (entry.get("model_info") or {}).get("id") or entry.get("model_id", "")
            if db_id:
                result[name] = db_id

    log.info(f"LiteLLM: {len(result)} modelos gerenciados atualmente registrados.")
    return result


def add_model(proxy_name: str, openrouter_id: str) -> bool:
    payload = {
        "model_name": proxy_name,
        "litellm_params": {
            "model": f"openrouter/{openrouter_id}",
            "api_key": "os.environ/OPENROUTER_API_KEY",
            "api_base": "https://openrouter.ai/api/v1",
        },
        "model_info": {
            "mode": "chat",
            "source": "openrouter-free-sync",
        },
    }
    try:
        resp = requests.post(
            f"{LITELLM_URL}/model/new",
            headers=litellm_headers(),
            json=payload,
            timeout=15,
        )
        resp.raise_for_status()
        log.info(f"  [+] Adicionado: {proxy_name} → openrouter/{openrouter_id}")
        return True
    except requests.HTTPError as e:
        log.warning(f"  [!] Falha ao adicionar {proxy_name}: {e.response.status_code} {e.response.text[:200]}")
        return False


def delete_model(proxy_name: str, db_id: str) -> bool:
    payload = {"id": db_id}
    try:
        resp = requests.post(
            f"{LITELLM_URL}/model/delete",
            headers=litellm_headers(),
            json=payload,
            timeout=15,
        )
        resp.raise_for_status()
        log.info(f"  [-] Removido: {proxy_name} (db_id={db_id})")
        return True
    except requests.HTTPError as e:
        log.warning(f"  [!] Falha ao remover {proxy_name}: {e.response.status_code} {e.response.text[:200]}")
        return False


# ─── Sync principal ───────────────────────────────────────────────────────────

def sync_once():
    log.info("═" * 60)
    log.info("Iniciando ciclo de sincronização...")

    try:
        or_free = fetch_openrouter_free()
    except Exception as e:
        log.error(f"Falha ao buscar modelos da OpenRouter: {e}")
        return

    try:
        ll_managed = fetch_litellm_managed()
    except Exception as e:
        log.error(f"Falha ao buscar modelos do LiteLLM: {e}")
        return

    or_names  = set(or_free.keys())
    ll_names  = set(ll_managed.keys())

    to_add    = or_names - ll_names
    to_remove = ll_names - or_names
    unchanged = or_names & ll_names

    log.info(f"Diff → adicionar: {len(to_add)} | remover: {len(to_remove)} | sem mudança: {len(unchanged)}")

    added = removed = 0

    for name in sorted(to_add):
        if add_model(name, or_free[name]):
            added += 1

    for name in sorted(to_remove):
        if delete_model(name, ll_managed[name]):
            removed += 1

    log.info(f"Ciclo concluído → +{added} adicionados | -{removed} removidos.")


# ─── Entry point ──────────────────────────────────────────────────────────────

def wait_for_litellm(max_wait: int = 120, interval: int = 5):
    """Aguarda o LiteLLM ficar disponível antes de iniciar o loop."""
    log.info(f"Aguardando LiteLLM em {LITELLM_URL}/health ...")
    elapsed = 0
    while elapsed < max_wait:
        try:
            r = requests.get(f"{LITELLM_URL}/health", timeout=5)
            if r.status_code < 500:
                log.info("LiteLLM disponível. Iniciando loop de sync.")
                return
        except requests.RequestException:
            pass
        time.sleep(interval)
        elapsed += interval
    log.warning("LiteLLM não respondeu em tempo. Iniciando de qualquer forma...")


if __name__ == "__main__":
    log.info(f"LiteLLM Free Model Sync iniciado. Intervalo: {SYNC_INTERVAL}s")
    wait_for_litellm()

    while True:
        try:
            sync_once()
        except Exception as e:
            log.exception(f"Erro não tratado no ciclo de sync: {e}")

        log.info(f"Próximo ciclo em {SYNC_INTERVAL}s...")
        time.sleep(SYNC_INTERVAL)
