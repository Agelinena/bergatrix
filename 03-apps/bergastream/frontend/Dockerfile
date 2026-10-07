FROM ghcr.io/cirruslabs/flutter:stable AS builder
WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get
COPY . .
# Os arquivos gerados (*.g.dart) já estão no repositório.
# Na web o app usa o mesmo domínio que o serve (nginx → /api/).
# --no-web-resources-cdn: CanvasKit e fontes saem do próprio servidor,
# sem depender de gstatic.com.
RUN flutter build web --release --no-web-resources-cdn

FROM nginx:alpine AS production
COPY --from=builder /app/build/web /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
