# 🍊 BERGATRIX

> **"This is your last chance. After this, there is no turning back. You take the blue pill—the story ends. You take the citrus pill—you stay in Wonderland, and I show you how deep the rabbit hole goes."**

A **Bergatrix** é o núcleo central de gerenciamento do meu homelab no **BergaServer**. Este repositório foi projetado para ser modular, seguro e totalmente focado em soberania de dados, refletindo minha jornada de "desgooglificação" e minha transição de carreira para a área de **Cybersecurity**.

---

## 📂 Arquitetura da Matrix

A estrutura segue uma lógica de dependência numérica, garantindo que os serviços essenciais estejam disponíveis para as aplicações de nível superior.

| Ordem | Gomo (Pasta) | Descrição | Status |
| :--- | :--- | :--- | :--- |
| **`00`** | **Infrastructure** | A base de tudo. Contém o **Postgres Global** e o **MinIO**. | 🏗️ *Em progresso* |
| **`01`** | **Network** | A casca protetora. Gerenciamento de tráfego com **Traefik** e exposição segura. | 🟢 *Ativo* |
| **`02`** | **Security** | O escudo da Matrix. Ferramentas como **Vaultwarden** e foco em segurança defensiva. | 🛡️ *Foco Cyber* |
| **`03`** | **Apps** | O recheio. Aplicações como **n8n**, **Jellyfin** e ferramentas de produtividade. | 🟢 *Ativo* |
| **`04`** | **Monitoring** | Os sentinelas. Monitoramento de saúde do servidor, logs e observabilidade. | 🔍 *Em Planejamento* |
| **`05`** | **Scripts** | Automação. Scripts para manutenção, backups e limpeza da Matrix. | ⚙️ *Utilitários* |

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

## 👤 Sobre o Autor

**Lucas**

* **Atual:** Analista de Marketing no Clube do Valor.
* **Alvo:** Especialista em Cybersecurity (Transição agendada para Julho de 2026).
* **Interesses:** Homelab, Docker, Privacidade de Dados, Escrita Criativa e Motociclismo.

> *"A Matrix é um sistema, Neo. Esse sistema é o nosso servidor."*