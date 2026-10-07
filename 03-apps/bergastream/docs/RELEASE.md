# Bergastream — versões dos apps (Android, Windows, Linux)

Os apps são gerados pelo GitHub Actions (`.github/workflows/bergastream-release.yml`, na raiz do
repositório) quando uma tag `bergastream-vX.Y.Z` é enviada. A release fica em
https://github.com/Agelinena/bergatrix/releases com:

| Arquivo | Plataforma |
|---|---|
| `bergastream-android.apk` | Android 7+ (APK universal, assinado) |
| `bergastream-windows-x64.zip` | Windows 10/11 64 bits |
| `bergastream-linux-x64.tar.gz` | Linux x64 |

Os apps instalados consultam essas releases ao abrir (no máximo uma vez a cada 20 h) e em
**Ajustes → Verificar atualizações**. Havendo versão nova, perguntam:

- **Baixar e instalar** (Android): baixa o APK e abre o instalador do sistema.
- **Baixar** (Windows/Linux): salva o pacote em Downloads e abre a pasta.
- **Ver no GitHub**: abre a página da versão.
- **Agora não**: não pergunta de novo por essa versão (só por uma mais nova).

O app procura exatamente esses nomes de arquivo e só tags que começam com `bergastream-v`
(o repositório tem outras stacks).

## Publicar uma versão

```bash
git tag bergastream-v0.2.0
git push origin bergastream-v0.2.0
```

O workflow roda os testes, compila os três apps e publica a release (~20 min). O número da
versão vem da tag (`0.2.0`; código do Android `200`, ou seja, `X*10000 + Y*100 + Z`). Não é
preciso mexer no `pubspec.yaml`, mas mantenha a versão dele igual à última tag para os builds
locais.

## Assinatura do Android (uma vez)

O Android só aceita uma atualização assinada **com a mesma chave** do app instalado. A chave fica
fora do repositório, em `~/Documentos/bergastream-assinatura-android/` (ver o `LEIA-ME.md` de
lá; **faça backup**). Cadastre no GitHub, em **Settings → Secrets and variables → Actions**:

| Secret | Valor |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | conteúdo de `upload.jks.base64` |
| `ANDROID_KEYSTORE_PASSWORD` | `storePassword` do `key.properties` |
| `ANDROID_KEY_ALIAS` | `upload` |
| `ANDROID_KEY_PASSWORD` | `keyPassword` do `key.properties` |

Sem esses secrets o job do Android falha de propósito (com aviso) e a release sai só com Windows
e Linux. Depois de cadastrar: **Actions → a execução → Re-run failed jobs** para acrescentar o APK.

## Build local

Precisa do Docker (a imagem `ghcr.io/cirruslabs/flutter` tem o SDK do Android).

```bash
cd 03-apps/bergastream/frontend
cp ~/Documentos/bergastream-assinatura-android/key.properties android/key.properties
flutter build apk --release --build-name=0.1.0 --build-number=100
flutter build linux --release --build-name=0.1.0 --build-number=100   # precisa das libs abaixo
```

Sem `android/key.properties` o APK de release sai com a chave de debug (serve para testar,
**não** para distribuir).

O Windows só compila no próprio Windows (ou no CI).

## Requisitos para quem instala

- **Android:** permitir "Instalar apps desconhecidos" para o navegador/gerenciador de arquivos
  (e para o Bergastream, na primeira atualização pelo app).
- **Windows:** o executável não é assinado; o SmartScreen pode avisar ("Mais informações →
  Executar assim mesmo").
- **Linux:** `libmpv` (áudio) e um chaveiro do sistema (`libsecret`, para guardar o login):
  `sudo apt install libmpv2 libsecret-1-0 gnome-keyring` (Debian/Ubuntu). Extraia e rode
  `bergastream/bergastream`.
