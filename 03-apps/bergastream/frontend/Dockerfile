FROM ghcr.io/cirruslabs/flutter:3.24.5 AS builder

WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY . .
RUN dart run build_runner build --delete-conflicting-outputs

# API_URL é passado pelo docker-compose como build arg
ARG API_URL=http://localhost:8000
RUN flutter build web --release --dart-define=API_URL=${API_URL}

FROM nginx:alpine AS production
COPY --from=builder /app/build/web /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
