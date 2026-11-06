# Berganews — app web (Flutter) servido pelo nginx, que repassa /api/ à API.
FROM ghcr.io/cirruslabs/flutter:3.44.0 AS builder
WORKDIR /app
COPY pubspec.yaml ./
RUN flutter pub get
COPY . .
# --no-web-resources-cdn: CanvasKit e fontes saem do próprio servidor, sem
# depender de gstatic.com.
RUN flutter build web --release --no-web-resources-cdn

FROM nginx:1.27-alpine AS production
COPY --from=builder /app/build/web /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
