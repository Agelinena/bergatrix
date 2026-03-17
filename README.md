# 🍊 BERGATRIX
> **"This is your last chance. After this, there is no turning back. You take the blue pill—the story ends. You take the citrus pill—you stay in Wonderland, and I show you how deep the rabbit hole goes."**

A **Bergatrix** é o núcleo central de gerenciamento do meu homelab no **BergaServer**. Este repositório foi projetado para ser modular, seguro e totalmente focado em soberania de dados, refletindo minha jornada de "desgooglificação" e minha transição de carreira para a área de **Cybersecurity**.

---

## 📂 Arquitetura da Matrix

A estrutura segue uma lógica de dependência numérica, garantindo que os serviços essenciais estejam disponíveis para as aplicações de nível superior.

| Ordem | Gomo (Pasta) | Descrição | Status |
| :--- | :--- | :--- | :--- |
| **`00`** | **Infrastructure** | A base de tudo. **AdGuard Home** para DNS filtering e **CloudBeaver** como interface de banco de dados. | 🟢 *Ativo* |
| **`01`** | **Network** | A casca protetora. Gerenciamento de tráfego com **Traefik** e túnel VPN via **WireGuard**. | 🟢 *Ativo* |
| **`02`** | **Security** | O escudo da Matrix. **Authentik** para SSO/IdP e **Bitwarden** (Vaultwarden) para gestão de senhas. | 🟢 *Ativo* |
| **`03`** | **Apps** | O recheio. Aplicações de produtividade, automação, IA e mídia. | 🟢 *Ativo* |
| **`04`** | **Monitoring** | Os sentinelas. **Wazuh** para SIEM, detecção de intrusão e observabilidade de segurança. | 🔍 *Em Configuração* |

---

## 📦 Apps (03-apps)

| App | Descrição |
| :--- | :--- |
| **Drop** | Serviço de transferência de arquivos self-hosted. |
| **GhostMap** | Aplicação web customizada (PWA). |
| **Jellyfin** | Servidor de mídia com stack customizada de legendas: pipeline de OCR, tradução automática e otimização via Bazarr. |
| **LiteLLM** | Proxy unificado de LLMs com updater automático de modelos gratuitos. |
| **n8n** | Plataforma de automação de workflows. |
| **Open WebUI** | Interface web para modelos de IA (conectado ao LiteLLM). |
| **RSS** | Agregador de feeds RSS self-hosted. |
| **Transcriptor** | Transcrição de áudio/vídeo com Faster-Whisper + GPU, desenvolvido internamente. |

---

## 🛡️ Pilares do Projeto

* **Soberania de Dados:** Redução da dependência de serviços de terceiros através do self-hosting e código aberto.
* **Security by Design:** Aplicação de práticas de *hardening* e isolamento de redes, alinhado aos estudos para as certificações **ISC2 CC** e **CompTIA Security+**.
* **Modularidade:** Cada stack Docker é independente, permitindo manutenções isoladas sem comprometer o ecossistema completo.

---

## 🚀 Como Iniciar

Para subir uma stack específica, navegue até a pasta desejada e execute o comando:

```bash
docker compose up -d
```

---

## 👤 Sobre o Autor

**Lucas**
* **Atual:** Analista de Marketing no Clube do Valor.
* **Alvo:** Especialista em Cybersecurity (Transição agendada para Julho de 2026).
* **Interesses:** Homelab, Docker, Privacidade de Dados, Escrita Criativa e Motociclismo.

> *"A Matrix é um sistema, Neo. Esse sistema é o nosso servidor."*
