# BergaStream

Plataforma de streaming de música multi-usuário, auto-hospedada, substituto do Spotify.

## Estrutura
- `backend/` — FastAPI (Python 3.12) + PostgreSQL + Redis + Alembic
- `frontend/` — Flutter (Web, Desktop, Android)
- `docker-compose.yml` — Produção (rede `bergatrix-proxy`)
- `docker-compose.dev.yml` — Desenvolvimento local

## Domínios
- **Web**: `WEB_DOMAIN=bergastream.seudominio.com`
- **API**: `API_DOMAIN=bergastreamapi.seudominio.com`
- A URL da API é injetada no Flutter em tempo de build via `--dart-define=API_URL`
- O `docker-compose.yml` passa isso automaticamente via `build.args`

## Desenvolvimento local

### Backend
```bash
cd backend
pip install -r requirements.txt
# Criar .env baseado em .env.example
docker compose -f ../docker-compose.dev.yml up db redis -d
alembic upgrade head
uvicorn app.main:app --reload
# API disponível em http://localhost:8000 | Docs em http://localhost:8000/api/docs
```

### Frontend (web dev)
```bash
cd frontend
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run -d chrome --dart-define=API_URL=http://localhost:8000
```

### Frontend (Android)

Build completo, incluindo regenerar os ícones a partir do logo (caso o
SVG mude):

```bash
cd frontend
flutter pub get
dart run build_runner build --delete-conflicting-outputs

# (Opcional) Regerar os ícones — só necessário se o logo mudou.
# Usa Pillow puro (não precisa libcairo nativa).
python scripts/generate_icons_pillow.py
dart run flutter_launcher_icons

# Build APK
flutter build apk --release --dart-define=API_URL=https://bergastreamapi.seudominio.com
# APK em frontend/build/app/outputs/flutter-apk/app-release.apk
```

Se quiser dividir por ABI (APK menor, ~40% do tamanho cada):
```bash
flutter build apk --release --split-per-abi --dart-define=API_URL=https://...
# Gera: app-armeabi-v7a-release.apk, app-arm64-v8a-release.apk, app-x86_64-release.apk
```

#### Notas sobre Android
- Reprodução em background depende do `just_audio_background` (já configurado).
  O `AndroidManifest.xml` declara o `AudioService` + `MediaButtonReceiver` —
  não remover.
- `minSdk = 21` é exigido pelo `just_audio_background`. O `flutter_launcher_icons`
  gera ícones adaptativos a partir de `assets/images/icon_1024.png` e
  `assets/images/icon_adaptive_fg.png`.
- Se o áudio não tocar, verificar no log do device (`adb logcat | grep -i audio`)
  se há erro de permissão `FOREGROUND_SERVICE_MEDIA_PLAYBACK` (Android 14+).
- O script `scripts/generate_icons.py` (cairosvg) renderiza a partir do SVG,
  mas requer `libcairo` instalada no SO.  Em Windows use a alternativa
  `scripts/generate_icons_pillow.py` que reproduz o mesmo desenho usando
  apenas Pillow.

### Frontend (Windows desktop)
```bash
cd frontend
flutter build windows --release --dart-define=API_URL=https://bergastreamapi.seudominio.com
# Executável em frontend/build/windows/x64/runner/Release/
```

### Docker (produção)
```bash
cp .env.example .env
# Editar .env: WEB_DOMAIN, API_DOMAIN, DEEMIX_ARL, JWT_SECRET_KEY, POSTGRES_PASSWORD, CORS_ORIGINS
docker compose up -d --build
docker compose exec api alembic upgrade head
# Web:  https://bergastream.seudominio.com
# API:  https://bergastreamapi.seudominio.com/api/docs
```

## Regras críticas de negócio

1. **Referência contada**: Um arquivo de música só é deletado fisicamente quando não há `playlist_tracks` nem `offline_tracks` apontando para ele.
2. **Cache 48h**: Músicas tocadas mas não em playlists ficam em `/data/music/cache/`. Job de limpeza roda a cada hora.
3. **Streaming chunked**: O endpoint `/api/stream/{id}` serve chunks enquanto baixa em paralelo. Nunca esperar o download completo.
4. **Segurança**: Todos os endpoints exceto `/api/auth/*` e `/api/cover/proxy` exigem JWT válido.

## Variáveis obrigatórias
- `DEEMIX_ARL` — Token ARL do Deezer (obtido via browser devtools após login)
- `JWT_SECRET_KEY` — Mínimo 32 caracteres, aleatório
- `POSTGRES_PASSWORD` — Senha forte

## Qualidade de áudio
- Deezer (com ARL válido): FLAC ou MP3 320kbps
- YouTube (fallback): MP3 128kbps via yt-dlp
