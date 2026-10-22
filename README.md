# 🍊 BERGATRIX
> **"This is your last chance. After this, there is no turning back. You take the blue pill—the story ends. You take the citrus pill—you stay in Wonderland, and I show you how deep the rabbit hole goes."**

A **Bergatrix** é o núcleo central de gerenciamento do meu homelab no **BergaServer**. Este repositório foi projetado para ser modular, seguro e totalmente focado em soberania de dados, refletindo minha jornada de "desgooglificação" e minha transição de carreira para a área de **Cybersecurity**.

---

## 📂 Arquitetura da Matrix

O servidor roda **Proxmox VE** com duas VMs: um **OpenMediaVault** (NAS, HD de 4 TB por NFS) e um **Ubuntu Server** com Docker, cujos configs e bancos ficam num HD local de 1 TB. As stacks seguem uma lógica de dependência numérica, garantindo que os serviços essenciais estejam disponíveis para as aplicações de nível superior.

| Ordem | Gomo (Pasta) | Descrição |
| :--- | :--- | :--- |
| **`00`** | **Infrastructure** | **CloudBeaver** como interface de banco de dados. |
| **`01`** | **Network** | Entrada de tráfego com **Traefik** (TLS curinga, roteamento por labels). |
| **`02`** | **Security** | **Authentik** (SSO/IdP), **Vaultwarden** (senhas) e **CrowdSec** (bloqueio de IPs). |
| **`03`** | **Apps** | Aplicações de produtividade, automação, IA e mídia. |
| **`04`** | **Monitoring** | **Homepage** (painel) e **Wazuh** (SIEM). |

📖 Documentação completa, padrões e guia para novas stacks: [`docs/`](docs/README.md).

---

## 📦 Apps (03-apps)

| App | Descrição |
| :--- | :--- |
| **Bergalink** | App próprio de localização em família (Flutter + FastAPI, login pelo Authentik). |
| **Bergastream** | Streaming de música próprio (Flutter + FastAPI), com Deemix, YouTube e Lidarr. |
| **Drop** | Transferência de arquivos cifrada de ponta a ponta. |
| **Home Assistant** | Automação residencial (dispositivos, automações e app Companion). |
| **Jellyfin** | Servidor de mídia com *arr, Seerr e o **Legendarr**: legendas pelo Bazarr, tradução local por IA (Ollama) e otimização de vídeo. |
| **LiteLLM** | Proxy unificado de LLMs com sincronizador automático de modelos. |
| **n8n** | Plataforma de automação de workflows. |
| **Open WebUI** | Interface web para modelos de IA, com **Ollama** na GPU. |
| **Transcriptor** | Transcrição de áudio/vídeo com Faster-Whisper + GPU, desenvolvido internamente. |

---

## 🛡️ Pilares do Projeto

* **Soberania de Dados:** Redução da dependência de serviços de terceiros através do self-hosting e código aberto.
* **Security by Design:** Aplicação de práticas de *hardening* e isolamento de redes, alinhado aos estudos para as certificações **ISC2 CC** e **CompTIA Security+**.
* **Modularidade:** Cada stack Docker é independente, permitindo manutenções isoladas sem comprometer o ecossistema completo.

---

## 🚀 Como Iniciar

Para subir uma stack específica, entre na pasta dela, crie o `.env` a partir do `.env.example` e execute:

```bash
cp .env.example .env   # e preencha
docker compose up -d
```

A ordem de subida e as dependências entre stacks estão em [`docs/01-infraestrutura.md`](docs/01-infraestrutura.md).

---

## 👤 Sobre o Autor

**Lucas**
* **Atual:** Analista de Marketing no Clube do Valor.
* **Alvo:** Especialista em Cybersecurity (Transição agendada para Julho de 2026).
* **Interesses:** Homelab, Docker, Privacidade de Dados, Escrita Criativa e Motociclismo.

> *"A Matrix é um sistema, Neo. Esse sistema é o nosso servidor."*
