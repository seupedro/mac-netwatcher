#!/bin/sh
# Refaz as imagens do README (docs/en e docs/pt) com 24 h de dados
# inventados, sem tocar nos dados de verdade em ~/.netwatch. Cada imagem e
# uma copia do app rodando por ~10 s com NETWATCH_DIR numa pasta temporaria;
# o icone delas aparece na barra de menus enquanto isso.
set -eu
cd "$(dirname "$0")/.."
scripts/compilar.sh >/dev/null
BIN="$PWD/build/Mac Netwatcher.app/Contents/MacOS/mac-netwatcher"
BASE=$(mktemp -d /tmp/netwatch-capturas.XXXX)

python3 -I - "$BASE" <<'PY'
import sys, time, random, math
d = sys.argv[1]
random.seed(7)
agora = int(time.time())
quedas = [(agora - 70000, 40), (agora - 30000, 18), (agora - 2400, 12)]
with open(d + "/samples.csv", "w") as f:
    f.write("horario,epoch,ms,alvo\n")
    for t in range(agora - 86400 + 4, agora, 2):
        fora = any(a <= t < a + n for a, n in quedas)
        h = time.localtime(t).tm_hour
        base = 14 + (10 if 19 <= h <= 22 else 0) + 3 * math.sin(t / 900)
        ms = base + random.gauss(0, 2.5) + (random.expovariate(1 / 40) if random.random() < 0.03 else 0)
        linha = ",,\n" if fora else ",%.1f,1.1.1.1:443\n" % max(ms, 6)
        f.write(time.strftime("%Y-%m-%dT%H:%M:%S-03:00", time.localtime(t)) + ",%d" % t + linha)
PY
: > "$BASE/events.log"

# uma: <arquivo> <idioma do sistema> VAR=valor...
uma() {
  saida=$1 lingua=$2
  shift 2
  d=$(mktemp -d "$BASE/run.XXXX")
  cp "$BASE/samples.csv" "$BASE/events.log" "$d/"
  env NETWATCH_DIR="$d" NETWATCH_PNG="$PWD/$saida" "$@" timeout 40 "$BIN" -AppleLanguages "($lingua)" >"$d/err.log" 2>&1 &
}

mkdir -p docs/en docs/pt
uma docs/en/panel-dark.png en-US NETWATCH_JANELA=3 NETWATCH_TEMA=escuro
uma docs/en/panel-light.png en-US NETWATCH_JANELA=3 NETWATCH_TEMA=claro
uma docs/pt/painel-escuro.png pt-BR NETWATCH_JANELA=3 NETWATCH_TEMA=escuro
uma docs/pt/painel-claro.png pt-BR NETWATCH_JANELA=3 NETWATCH_TEMA=claro
# os pocos de cor saem com um quadrado branco em volta na imagem; no tema
# claro quase nao aparece
for aba in cores idioma sobre; do
  case $aba in cores) en=colors ;; idioma) en=language ;; sobre) en=about ;; esac
  uma docs/en/settings-$en.png en-US NETWATCH_PNG_AJUSTES=1 NETWATCH_ABA=$aba NETWATCH_TEMA=claro
  uma docs/pt/ajustes-$aba.png pt-BR NETWATCH_PNG_AJUSTES=1 NETWATCH_ABA=$aba NETWATCH_TEMA=claro
done
wait
ls -l docs/en docs/pt
