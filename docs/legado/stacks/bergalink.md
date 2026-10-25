# Bergalink

App Android Flutter para compartilhar localização com familiares convidados. Estado atual: MVP em
desenvolvimento; não implantar para uso familiar até configurar Authentik/Firebase e testar em
aparelhos reais.

## Estado atual

O Android usa Authentik/OIDC, API FastAPI, grupos PostgreSQL, mapa OpenStreetMap, localização
foreground e pings. A prévia web segue isolada com dados fictícios. Authentik/Firebase ainda não
estão provisionados e o serviço de localização precisa de validação em aparelhos reais.

O app fica em `03-apps/bergalink/`; `README.md` descreve configuração e deploy. O pacote Android é
`com.bergatrix.bergalink`. `docker-compose.yml` define API/PostgreSQL; o banco não publica portas.

## Segurança planejada

- Authentik é o único provedor de contas; cadastro público não existe. `bergalink-users` libera
  acesso e `bergalink-admins` dá privilégios administrativos. O mantenedor pertence aos dois.
- O backend valida grupo em cada rota e WebSocket; remoção fecha conexões ativas.
- Compartilhamento começa desligado e é configurado por grupo.
- Só a última posição fica no banco; apaga após 180 s sem atualização. Payloads FCM não incluem
  coordenadas; pings expiram em 24 h.
- Android usa foreground service com notificação; intervalo pedido de 45 s e deslocamento mínimo
  de 75 m (o sistema pode atrasar updates e afetar bateria).

Requisitos e critérios de beta: [SECURITY.md](../../03-apps/bergalink/docs/SECURITY.md).

## Automação

- `bergalink-ci.yml` verifica alterações nessa pasta com Flutter e backend/PostgreSQL.
- `bergalink-release.yml` publica APK assinado apenas para tags `bergalink-vX.Y.Z`.
- O release exige chave exclusiva nos secrets `BERGALINK_ANDROID_*`; não reutilizar a assinatura do
  Bergastream. O atualizador futuro deve consultar apenas tags `bergalink-v*`.

Antes do deploy: provisionar grupos/provider no Authentik e configurar `.env`; para push com app
fechado, criar projeto Firebase, instalar a service account fora do repo e configurar Actions
Variables para o APK. Ver o README para os passos completos.