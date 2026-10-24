#!/bin/sh
# Compila, copia para "/Applications/Mac Netwatcher.app" e liga o LaunchAgent:
# abre no login e o launchd so reabre se travar ("Sair" fecha de verdade).
# Rodar de novo depois de mudar o codigo troca o app e reinicia. O
# Netwatch.app de antes da troca de nome vai para a Lixeira.
# Para desinstalar: scripts/instalar.sh --remover
set -eu
cd "$(dirname "$0")/.."
ROTULO=xyz.paralaxe.netwatch
APP="/Applications/Mac Netwatcher.app"
ANTIGO=/Applications/Netwatch.app
PLIST="$HOME/Library/LaunchAgents/$ROTULO.plist"
ALVO="gui/$(id -u)/$ROTULO"

lixeira() {
  [ -e "$1" ] || return 0
  if [ -x /usr/bin/trash ]; then
    /usr/bin/trash "$1"
  else
    mv "$1" "$HOME/.Trash/$(basename "$1") $(date +%Y%m%d%H%M%S)"
  fi
}

if [ "${1:-}" = --remover ]; then
  launchctl bootout "$ALVO" 2>/dev/null || true
  lixeira "$PLIST"
  lixeira "$APP"
  lixeira "$ANTIGO"
  echo "removido (app e LaunchAgent na Lixeira; os dados ficam em ~/.netwatch)"
  exit 0
fi

scripts/compilar.sh
if launchctl print "$ALVO" >/dev/null 2>&1; then
  launchctl bootout "$ALVO" 2>/dev/null || true
  sleep 1
fi
lixeira "$ANTIGO"
mkdir -p "$APP"
ditto "build/Mac Netwatcher.app" "$APP"

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat >| "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$ROTULO</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/mac-netwatcher</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/Netwatch.log</string>
</dict>
</plist>
PL

launchctl bootstrap "gui/$(id -u)" "$PLIST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
echo "ok: $APP rodando pelo launchd ($ALVO)"
