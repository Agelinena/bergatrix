#!/bin/sh
# Roda a cada start do app, depois do 10-exige-instalacao.sh (hook before-starting).
#
# Aplica o tema "Drive" da web: as cores e o fundo liso pelo tema do Nextcloud
# e o CSS de /tema/drive.css (pasta tema/ do repositório) pelo app Custom CSS.
# Só grava o que mudou, para o navegador não baixar o tema de novo à toa.
# Um erro aqui só avisa no log: o Nextcloud sobe com o tema que já tinha.
set -u

occ() { php /var/www/html/occ "$@"; }
avisa() { echo "AVISO (tema): $*" >&2; }

# Grava um valor de app só se for diferente do atual
ajusta() { # app chave valor
  [ "$(occ config:app:get "$1" "$2" 2>/dev/null)" = "$3" ] && return 0
  occ config:app:set "$1" "$2" --value="$3" >/dev/null && echo "tema: $1 $2 atualizado"
}

# Cores do Drive (Material 3) e fundo liso, sem imagem
[ "$(occ config:app:get theming primary_color 2>/dev/null)" = "#0b57d0" ] || occ theming:config primary_color "#0b57d0" || avisa "cor principal"
[ "$(occ config:app:get theming background_color 2>/dev/null)" = "#f8fafd" ] || occ theming:config background_color "#f8fafd" || avisa "cor de fundo"
[ "$(occ config:app:get theming backgroundMime 2>/dev/null)" = "backgroundColor" ] || occ theming:config background backgroundColor || avisa "fundo liso"
[ "$(occ config:app:get theming disable-user-theming 2>/dev/null)" = "1" ] || occ theming:config disable-user-theming yes || avisa "tema por usuário"

# Sem o bloco de Readme.md no topo das pastas (app Text)
ajusta text workspace_available 0 || avisa "Readme nas pastas"

# CSS próprio: o app Custom CSS precisa estar instalado (vem da loja de apps)
if ! occ app:enable theming_customcss >/dev/null 2>&1; then
  occ app:install theming_customcss >/dev/null 2>&1 || { avisa "não instalou o app theming_customcss"; exit 0; }
fi
css=$(cat /tema/drive.css) || { avisa "não leu /tema/drive.css"; exit 0; }
if [ "$(occ config:app:get theming_customcss customcss 2>/dev/null)" != "$css" ]; then
  occ config:app:set theming_customcss customcss --value="$css" >/dev/null &&
    occ config:app:set theming_customcss cachebuster --value="$(date +%s)" >/dev/null &&
    echo "tema: CSS atualizado" || avisa "não gravou o CSS"
fi
exit 0
