"""
LiteLLM Model Sync — Sidecar
Sincroniza dinamicamente modelos da OpenRouter e Ollama com o LiteLLM Proxy via API REST.
"""

import os
import time
import logging
import requests

# ─── Configuração ─────────────────────────────────────────────────────────────
LITELLM_URL    = os.environ.get("LITELLM_URL", "http://litellm:4000")
MASTER_KEY     = os.environ["LITELLM_MASTER_KEY"]
OPENROUTER_KEY = os.environ["OPENROUTER_API_KEY"]
OLLAMA_URL     = os.environ.get("OLLAMA_URL", "http://ollama:11434")
SYNC_INTERVAL  = int(os.environ.get("SYNC_INTERVAL", "3600"))

OR_MODELS_URL  = "https://openrouter.ai/api/v1/models"

FREE_PREFIX    = "or-free/"
PAID_PREFIX    = "or-paid/"
OLLAMA_PREFIX  = "ollama/"

FREE_KEY_ALIAS = "free-models-key"
PAID_KEY_ALIAS = "paid-models-key"

# Modelos estáticos que NÃO devem ser adicionados à key de pagos
# (gerenciados manualmente no config.yaml)
STATIC_MODELS = {
    "deepseek-v3",
}

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("model-sync")


# ─── Helpers ──────────────────────────────────────────────────────────────────

def litellm_headers() -> dict:
    return {
        "Authorization": f"Bearer {MASTER_KEY}",
        "Content-Type": "application/json",
    }

def is_free(model: dict) -> bool:
    model_id = model.get("id", "")
    if model_id.endswith(":free"):
        return True
    pricing = model.get("pricing", {})
    try:
        return (
            float(pricing.get("prompt", "1")) == 0
            and float(pricing.get("completion", "1")) == 0
        )
    except (TypeError, ValueError):
        return False


# ─── Ollama ───────────────────────────────────────────────────────────────────

def fetch_ollama_models() -> dict[str, str] | None:
    """
    Retorna { proxy_name → upstream_name }
    Exemplo: { "ollama/llama3" → "llama3" }
    Retorna None em caso de falha de conexão (para não deletar modelos por acidente).
    """
    try:
        resp = requests.get(f"{OLLAMA_URL}/api/tags", timeout=10)
        resp.raise_for_status()
        data = resp.json().get("models", [])
        
        ollama: dict[str, str] = {}
        for m in data:
            name = m.get("name")
            if name:
                ollama[f"{OLLAMA_PREFIX}{name}"] = name
                
        log.info(f"Ollama: {len(ollama)} modelos locais encontrados.")
        return ollama
    except requests.RequestException as e:
        log.warning(f"Ollama offline ou inacessível: {e}")
        return None


# ─── OpenRouter ───────────────────────────────────────────────────────────────

def fetch_openrouter_models() -> tuple[dict[str, str], dict[str, str]]:
    resp = requests.get(
        OR_MODELS_URL,
        headers={"Authorization": f"Bearer {OPENROUTER_KEY}"},
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json().get("data", [])

    free: dict[str, str] = {}
    paid: dict[str, str] = {}

    for m in data:
        model_id: str = m.get("id", "")
        if not model_id:
            continue

        if is_free(m):
            clean = model_id.replace(":free", "").strip("/")
            free[f"{FREE_PREFIX}{clean}"] = model_id
        else:
            clean = model_id.strip("/")
            paid[f"{PAID_PREFIX}{clean}"] = model_id

    log.info(f"OpenRouter: {len(free)} modelos free | {len(paid)} modelos pagos.")
    return free, paid


# ─── LiteLLM — modelos ────────────────────────────────────────────────────────

def fetch_litellm_managed(prefix: str) -> dict[str, str]:
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
        if name.startswith(prefix):
            db_id = (
                (entry.get("model_info") or {}).get("id")
                or entry.get("model_id", "")
            )
            if db_id:
                result[name] = db_id

    log.info(f"LiteLLM [{prefix}]: {len(result)} modelos registrados.")
    return result


def add_model(proxy_name: str, upstream_id: str, provider: str) -> bool:
    if provider == "openrouter":
        litellm_params = {
            "model": f"openrouter/{upstream_id}",
            "api_key": OPENROUTER_KEY,
            "api_base": "https://openrouter.ai/api/v1",
        }
    elif provider == "ollama":
        litellm_params = {
            "model": f"ollama/{upstream_id}",
            "api_base": OLLAMA_URL,
        }
    else:
        return False

    payload = {
        "model_name": proxy_name,
        "litellm_params": litellm_params,
        "model_info": {
            "mode": "chat",
            "source": f"{provider}-sync",
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
        log.info(f"  [+] {proxy_name} → {litellm_params['model']}")
        return True
    except requests.HTTPError as e:
        log.warning(f"  [!] Falha ao adicionar {proxy_name}: {e.response.status_code} {e.response.text[:200]}")
        return False


def delete_model(proxy_name: str, db_id: str) -> bool:
    try:
        resp = requests.post(
            f"{LITELLM_URL}/model/delete",
            headers=litellm_headers(),
            json={"id": db_id},
            timeout=15,
        )
        resp.raise_for_status()
        log.info(f"  [-] {proxy_name} (db_id={db_id})")
        return True
    except requests.HTTPError as e:
        log.warning(f"  [!] Falha ao remover {proxy_name}: {e.response.status_code} {e.response.text[:200]}")
        return False


# ─── LiteLLM — virtual keys ───────────────────────────────────────────────────

# ─── LiteLLM — virtual keys ───────────────────────────────────────────────────

def fetch_existing_key(alias: str) -> dict | None:
    try:
        resp = requests.get(
            f"{LITELLM_URL}/key/list",
            headers=litellm_headers(),
            timeout=15,
        )
        resp.raise_for_status()
        data = resp.json()
        
        # Navegação super segura no JSON (protege contra mudanças na API do LiteLLM)
        keys = data.get("keys", []) if isinstance(data, dict) else []
        
        # Em algumas versões, o LiteLLM coloca tudo dentro de "data"
        if not keys and isinstance(data, dict) and "data" in data:
            if isinstance(data["data"], list):
                keys = data["data"]
                
        if not isinstance(keys, list):
            log.warning(f"Formato inesperado em /key/list: {type(keys)}")
            return None

        # Busca segura pela chave
        for k in keys:
            if isinstance(k, dict) and k.get("key_alias") == alias:
                return k
                
        return None
    except Exception as e:
        log.warning(f"Falha ao buscar key '{alias}': {e}")
        return None

def upsert_virtual_key(alias: str, model_names: list[str], description: str) -> str | None:
    if not model_names:
        log.warning(f"Nenhum modelo para a key '{alias}', pulando.")
        return None

    existing = fetch_existing_key(alias)

    if existing:
        token = existing.get("token") or existing.get("key")
        if not token:
            log.warning(f"Key '{alias}' encontrada mas sem token, recriando...")
            existing = None

    if existing:
        token = existing.get("token") or existing.get("key")
        payload = {
            "key": token,
            "models": model_names,
            "metadata": {"description": description, "managed_by": "sidecar-sync"},
        }
        try:
            resp = requests.post(
                f"{LITELLM_URL}/key/update",
                headers=litellm_headers(),
                json=payload,
                timeout=15,
            )
            resp.raise_for_status()
            log.info(f"Virtual key '{alias}' atualizada → {len(model_names)} modelos.")
            return token
        except requests.HTTPError as e:
            # Agora imprimimos o motivo real do erro!
            log.warning(f"Falha ao atualizar key '{alias}': HTTP {e.response.status_code} - {e.response.text[:200]}")
            return None
    else:
        payload = {
            "key_alias": alias,
            "models": model_names,
            "metadata": {"description": description, "managed_by": "sidecar-sync"},
        }
        try:
            resp = requests.post(
                f"{LITELLM_URL}/key/generate",
                headers=litellm_headers(),
                json=payload,
                timeout=15,
            )
            resp.raise_for_status()
            token = resp.json().get("key")
            log.info(f"Virtual key '{alias}' CRIADA → {len(model_names)} modelos.")
            return token
        except requests.HTTPError as e:
            # Imprimimos o motivo do 400
            log.warning(f"Falha ao criar key '{alias}': HTTP {e.response.status_code} - {e.response.text[:200]}")
            return None

def upsert_virtual_key(alias: str, model_names: list[str], description: str) -> str | None:
    if not model_names:
        log.warning(f"Nenhum modelo para a key '{alias}', pulando.")
        return None

    existing = fetch_existing_key(alias)

    if existing:
        token = existing.get("token") or existing.get("key")
        if not token:
            log.warning(f"Key '{alias}' encontrada mas sem token, recriando...")
            existing = None

    if existing:
        token = existing.get("token") or existing.get("key")
        payload = {
            "key": token,
            "models": model_names,
            "metadata": {"description": description, "managed_by": "sidecar-sync"},
        }
        try:
            resp = requests.post(
                f"{LITELLM_URL}/key/update",
                headers=litellm_headers(),
                json=payload,
                timeout=15,
            )
            resp.raise_for_status()
            log.info(f"Virtual key '{alias}' atualizada → {len(model_names)} modelos.")
            return token
        except requests.HTTPError as e:
            log.warning(f"Falha ao atualizar key '{alias}': {e.response.status_code}")
            return None
    else:
        payload = {
            "key_alias": alias,
            "models": model_names,
            "metadata": {"description": description, "managed_by": "sidecar-sync"},
        }
        try:
            resp = requests.post(
                f"{LITELLM_URL}/key/generate",
                headers=litellm_headers(),
                json=payload,
                timeout=15,
            )
            resp.raise_for_status()
            token = resp.json().get("key")
            log.info(f"Virtual key '{alias}' CRIADA → {len(model_names)} modelos.")
            return token
        except requests.HTTPError as e:
            log.warning(f"Falha ao criar key '{alias}': {e.response.status_code}")
            return None


# ─── Sync principal ───────────────────────────────────────────────────────────

def sync_once():
    log.info("═" * 60)
    log.info("Iniciando ciclo de sincronização...")

    # 1. Busca modelos da OpenRouter e Ollama
    try:
        or_free, or_paid = fetch_openrouter_models()
    except Exception as e:
        log.error(f"Falha ao buscar modelos da OpenRouter: {e}")
        return

    ollama_models = fetch_ollama_models() # Retorna None se falhar
    ollama_names = set(ollama_models.keys()) if ollama_models else set()

    # 2. Busca modelos gerenciados no LiteLLM
    try:
        ll_free   = fetch_litellm_managed(FREE_PREFIX)
        ll_paid   = fetch_litellm_managed(PAID_PREFIX)
        ll_ollama = fetch_litellm_managed(OLLAMA_PREFIX) if ollama_models is not None else None
    except Exception as e:
        log.error(f"Falha ao buscar modelos do LiteLLM: {e}")
        return

    # 3. Sync modelos FREE (OpenRouter)
    log.info("── Modelos FREE (OpenRouter) ──")
    free_names = set(or_free.keys())
    free_ll    = set(ll_free.keys())
    for name in sorted(free_names - free_ll):
        add_model(name, or_free[name], "openrouter")
    for name in sorted(free_ll - free_names):
        delete_model(name, ll_free[name])

    # 4. Sync modelos PAGOS (OpenRouter)
    log.info("── Modelos PAGOS (OpenRouter) ──")
    paid_names = set(or_paid.keys())
    paid_ll    = set(ll_paid.keys())
    for name in sorted(paid_names - paid_ll):
        add_model(name, or_paid[name], "openrouter")
    for name in sorted(paid_ll - paid_names):
        delete_model(name, ll_paid[name])

    # 5. Sync modelos OLLAMA (Locais)
    if ollama_models is not None and ll_ollama is not None:
        log.info("── Modelos LOCAIS (Ollama) ──")
        ollama_ll_set = set(ll_ollama.keys())
        for name in sorted(ollama_names - ollama_ll_set):
            add_model(name, ollama_models[name], "ollama")
        for name in sorted(ollama_ll_set - ollama_names):
            delete_model(name, ll_ollama[name])
    else:
        log.warning("Pulando sincronização do Ollama neste ciclo devido a falha de conexão.")

    # 6. Atualiza virtual keys
    log.info("── Virtual Keys ──")

    # Free key: modelos or-free/ + ollama/
    free_model_list = sorted(free_names) + sorted(ollama_names)
    upsert_virtual_key(
        alias=FREE_KEY_ALIAS,
        model_names=free_model_list,
        description="Modelos gratuitos da OpenRouter e Locais do Ollama",
    )

    # Paid key: modelos or-paid/ + ollama/ + aliases estáticos
    paid_model_list = sorted(paid_names) + sorted(ollama_names) + sorted(STATIC_MODELS)
    upsert_virtual_key(
        alias=PAID_KEY_ALIAS,
        model_names=paid_model_list,
        description="Modelos pagos, locais e estáticos",
    )

    log.info("Ciclo concluído.")


# ─── Startup ──────────────────────────────────────────────────────────────────

def wait_for_litellm(max_wait: int = 120, interval: int = 5):
    log.info(f"Aguardando LiteLLM em {LITELLM_URL} ...")
    elapsed = 0
    while elapsed < max_wait:
        try:
            r = requests.get(f"{LITELLM_URL}/health/liveliness", timeout=5)
            if r.status_code < 500:
                log.info(f"LiteLLM disponível (status {r.status_code}).")
                return
        except requests.RequestException:
            pass
        time.sleep(interval)
        elapsed += interval
    log.warning("LiteLLM não respondeu a tempo. Iniciando de qualquer forma...")

if __name__ == "__main__":
    log.info(f"LiteLLM Model Sync iniciado. Intervalo: {SYNC_INTERVAL}s")
    wait_for_litellm()

    while True:
        try:
            sync_once()
        except Exception as e:
            log.exception(f"Erro não tratado no ciclo de sync: {e}")

        log.info(f"Próximo ciclo em {SYNC_INTERVAL}s...")
        time.sleep(SYNC_INTERVAL)