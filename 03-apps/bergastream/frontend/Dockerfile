FROM ghcr.io/cirruslabs/flutter:stable AS builder

WORKDIR /app

# Copia só o pubspec.yaml — lock não é commitado, será gerado aqui
COPY pubspec.yaml ./
RUN flutter pub get

# Copia o restante do código (inclui web/ com index.html e assets/)
COPY . .

# Gera os arquivos .g.dart (Riverpod @riverpod annotations)
RUN dart run build_runner build --delete-conflicting-outputs

# API_URL é passado pelo docker-compose como build arg
ARG API_URL=http://localhost:8000
RUN flutter build web --release --dart-define=API_URL=${API_URL}

FROM nginx:alpine AS production
COPY --from=builder /app/build/web /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
