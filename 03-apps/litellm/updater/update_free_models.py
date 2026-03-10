"""
LiteLLM Model Sync — Sidecar
Sincroniza dinamicamente modelos da OpenRouter com o LiteLLM Proxy via API REST.

Lógica por ciclo:
  1. Fetch OpenRouter /models  → separa modelos :free e pagos
  2. Fetch LiteLLM /model/info → lê modelos gerenciados (prefixos or-free/ e or-paid/)
  3. Diff add/remove para cada grupo
  4. POST /model/new  (novos)
  5. POST /model/delete (removidos)
  6. Atualiza virtual keys: "free-models-key" e "paid-models-key"
  7. Sleep SYNC_INTERVAL segundos
"""

import os
import time
import logging
import requests

# ─── Configuração ─────────────────────────────────────────────────────────────
LITELLM_URL    = os.environ.get("LITELLM_URL", "http://litellm:4000")
MASTER_KEY     = os.environ["LITELLM_MASTER_KEY"]
OPENROUTER_KEY = os.environ["OPENROUTER_API_KEY"]
SYNC_INTERVAL  = int(os.environ.get("SYNC_INTERVAL", "3600"))

OR_MODELS_URL  = "https://openrouter.ai/api/v1/models"

FREE_PREFIX    = "or-free/"
PAID_PREFIX    = "or-paid/"
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
        return (
            float(pricing.get("prompt", "1")) == 0
            and float(pricing.get("completion", "1")) == 0
        )
    except (TypeError, ValueError):
        return False


# ─── OpenRouter ───────────────────────────────────────────────────────────────

def fetch_openrouter_models() -> tuple[dict[str, str], dict[str, str]]:
    """
    Retorna dois dicts: (free_models, paid_models)
    Cada dict: { proxy_name → openrouter_model_id }

    Exemplos:
      free: { "or-free/google/gemini-2.0-flash-exp" → "google/gemini-2.0-flash-exp:free" }
      paid: { "or-paid/anthropic/claude-3.5-sonnet" → "anthropic/claude-3.5-sonnet"      }
    """
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
            # Remove ":free" do nome do proxy para evitar ":" no model_name
            clean = model_id.replace(":free", "").strip("/")
            free[f"{FREE_PREFIX}{clean}"] = model_id
        else:
            clean = model_id.strip("/")
            paid[f"{PAID_PREFIX}{clean}"] = model_id

    log.info(f"OpenRouter: {len(free)} modelos free | {len(paid)} modelos pagos.")
    return free, paid


# ─── LiteLLM — modelos ────────────────────────────────────────────────────────

def fetch_litellm_managed(prefix: str) -> dict[str, str]:
    """
    Retorna { model_name → db_id } para modelos com o prefixo especificado.
    db_id é necessário para deletar via /model/delete.
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
        if name.startswith(prefix):
            db_id = (
                (entry.get("model_info") or {}).get("id")
                or entry.get("model_id", "")
            )
            if db_id:
                result[name] = db_id

    log.info(f"LiteLLM [{prefix}]: {len(result)} modelos registrados.")
    return result


def add_model(proxy_name: str, openrouter_id: str) -> bool:
    payload = {
        "model_name": proxy_name,
        "litellm_params": {
            "model": f"openrouter/{openrouter_id}",
            "api_key": OPENROUTER_KEY,
            "api_base": "https://openrouter.ai/api/v1",
        },
        "model_info": {
            "mode": "chat",
            "source": "openrouter-sync",
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
        log.info(f"  [+] {proxy_name} → openrouter/{openrouter_id}")
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


def sync_models(
    or_models: dict[str, str],
    ll_managed: dict[str, str],
    label: str,
) -> int:
    """
    Executa o diff e aplica add/delete. Retorna o total de modelos ativos após sync.
    """
    or_names  = set(or_models.keys())
    ll_names  = set(ll_managed.keys())
    to_add    = or_names - ll_names
    to_remove = ll_names - or_names

    log.info(f"[{label}] +{len(to_add)} / -{len(to_remove)} / ={len(or_names & ll_names)}")

    for name in sorted(to_add):
        add_model(name, or_models[name])

    for name in sorted(to_remove):
        delete_model(name, ll_managed[name])

    # Retorna o conjunto atualizado de nomes
    return list((or_names - to_add) | (or_names & ll_names) | to_add - to_remove)


# ─── LiteLLM — virtual keys ───────────────────────────────────────────────────

def fetch_existing_key(alias: str) -> dict | None:
    """Busca uma virtual key pelo alias. Retorna o objeto completo ou None."""
    try:
        resp = requests.get(
            f"{LITELLM_URL}/key/list",
            headers=litellm_headers(),
            params={"key_alias": alias},
            timeout=15,
        )
        resp.raise_for_status()
        keys = resp.json().get("keys", [])
        return next((k for k in keys if k.get("key_alias") == alias), None)
    except Exception as e:
        log.warning(f"Falha ao buscar key '{alias}': {e}")
        return None


def upsert_virtual_key(alias: str, model_names: list[str], description: str) -> str | None:
    """
    Cria ou atualiza uma virtual key com a lista de modelos fornecida.
    Retorna o token da key (apenas no momento da criação).
    """
    if not model_names:
        log.warning(f"Nenhum modelo para a key '{alias}', pulando.")
        return None

    existing = fetch_existing_key(alias)

    if existing:
        token = existing.get("token") or existing.get("key")
        if not token:
            log.warning(f"Key '{alias}' encontrada mas sem token identificável, recriando...")
            existing = None

    if existing:
        token = existing.get("token") or existing.get("key")
        payload = {
            "key": token,
            "models": model_names,
            "metadata": {"description": description, "managed_by": "openrouter-sync"},
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
            log.warning(f"Falha ao atualizar key '{alias}': {e.response.status_code} {e.response.text[:300]}")
            return None
    else:
        payload = {
            "key_alias": alias,
            "models": model_names,
            "metadata": {"description": description, "managed_by": "openrouter-sync"},
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
            log.info(f"  Token: {token}")
            log.info(f"  *** Salve este token, ele não será exibido novamente! ***")
            return token
        except requests.HTTPError as e:
            log.warning(f"Falha ao criar key '{alias}': {e.response.status_code} {e.response.text[:300]}")
            return None


# ─── Sync principal ───────────────────────────────────────────────────────────

def sync_once():
    log.info("═" * 60)
    log.info("Iniciando ciclo de sincronização...")

    # 1. Busca modelos da OpenRouter
    try:
        or_free, or_paid = fetch_openrouter_models()
    except Exception as e:
        log.error(f"Falha ao buscar modelos da OpenRouter: {e}")
        return

    # 2. Busca modelos gerenciados no LiteLLM
    try:
        ll_free = fetch_litellm_managed(FREE_PREFIX)
        ll_paid = fetch_litellm_managed(PAID_PREFIX)
    except Exception as e:
        log.error(f"Falha ao buscar modelos do LiteLLM: {e}")
        return

    # 3. Sync modelos free
    log.info("── Modelos FREE ──")
    free_names = set(or_free.keys())
    free_ll    = set(ll_free.keys())
    for name in sorted(free_names - free_ll):
        add_model(name, or_free[name])
    for name in sorted(free_ll - free_names):
        delete_model(name, ll_free[name])

    # 4. Sync modelos pagos
    log.info("── Modelos PAGOS ──")
    paid_names = set(or_paid.keys())
    paid_ll    = set(ll_paid.keys())
    for name in sorted(paid_names - paid_ll):
        add_model(name, or_paid[name])
    for name in sorted(paid_ll - paid_names):
        delete_model(name, ll_paid[name])

    # 5. Atualiza virtual keys
    log.info("── Virtual Keys ──")

    # Free key: apenas modelos or-free/
    upsert_virtual_key(
        alias=FREE_KEY_ALIAS,
        model_names=sorted(free_names),
        description="Modelos gratuitos da OpenRouter — gerenciado pelo sidecar",
    )

    # Paid key: modelos or-paid/ + modelos estáticos do config.yaml
    paid_model_list = sorted(paid_names) + sorted(STATIC_MODELS)
    upsert_virtual_key(
        alias=PAID_KEY_ALIAS,
        model_names=paid_model_list,
        description="Modelos pagos da OpenRouter + aliases estáticos — gerenciado pelo sidecar",
    )

    log.info("Ciclo concluído.")


# ─── Startup ──────────────────────────────────────────────────────────────────

def wait_for_litellm(max_wait: int = 120, interval: int = 5):
    """Aguarda o LiteLLM ficar disponível antes de iniciar o loop."""
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
