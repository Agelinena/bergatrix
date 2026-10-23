# Bibliotecas de terceiros

Servidas pelo próprio Drop (nada de CDN): a página só carrega arquivos da mesma origem.
Para atualizar, baixe com `npm pack <pacote>@<versão>` (o npm confere a integridade),
copie o arquivo e atualize a tabela.

| Arquivo | Pacote | Licença | SHA-256 |
|---|---|---|---|
| `qrcode.mjs` | `qrcode-generator@2.0.4` (`dist/qrcode.mjs`) | MIT, Kazuhiko Arase | `ea91d7118a5395289170da848b7c6758b996163bfbccf312591ab65a4911b7c0` |
| `jsQR.js` | `jsqr@1.4.0` (`dist/jsQR.js`) | Apache-2.0, Cosmo Wolfe | `bc40c8a15196236b2314db0856f72ca0b49980cd5413b8c852a7349f5fee0859` |
| `../fonts/manrope-latin-wght-normal.woff2` | `@fontsource-variable/manrope@5.3.0` | SIL OFL 1.1 | `a30ddcd349703aff7464c34bef3fffdff405ee50c113440d7c8693c02d210972` |
| `../fonts/space-mono-latin-400-normal.woff2` | `@fontsource/space-mono@5.3.0` | SIL OFL 1.1 | `fb4a81a2d0a893e5c38c394a7e716a1cef0b24610a0af49c96f6d529bd66bf2b` |
| `../fonts/space-mono-latin-700-normal.woff2` | `@fontsource/space-mono@5.3.0` | SIL OFL 1.1 | `2d46bd159b53f55c41167a4f1540a074649464194fd1e416f5b4694a6c0f282c` |

Conferir: `cd app/static/assets && sha256sum vendor/*.js vendor/*.mjs fonts/*`
