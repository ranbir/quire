#!/bin/sh
# Refreshes the diagram libraries bundled in Resources/preview:
#
#   mermaid/mermaid.min.js   Mermaid (MIT), with ELK (EPL-2.0) inlined
#   d2/d2.js                 D2 (MPL-2.0) with ELK (EPL-2.0), WebAssembly inlined, exposed as window.QuireD2
#   graphviz/graphviz.js     Graphviz (EPL-2.0) via @hpcc-js/wasm-graphviz (Apache-2.0),
#                            exposed as window.QuireGraphviz
#
#   tools/vendor-diagrams.sh
#
# Needs npm, bun and curl. Change the versions below and run it again to upgrade.
set -e
cd "$(dirname "$0")/.."

MERMAID=12.1.0
D2=0.1.33
GRAPHVIZ=1.29.2

OUT=Resources/preview
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

(cd "$WORK" && npm init -y >/dev/null && npm install --ignore-scripts --no-audit --no-fund \
    "mermaid@$MERMAID" "@terrastruct/d2@$D2" "@hpcc-js/wasm-graphviz@$GRAPHVIZ" >/dev/null)
M="$WORK/node_modules"

# Mermaid ships a single-file build; use it as is.
mkdir -p "$OUT/mermaid"
cp "$M/mermaid/dist/mermaid.min.js" "$OUT/mermaid/mermaid.min.js"
cp "$M/mermaid/LICENSE" "$OUT/mermaid/LICENSE"
cp "$M/elkjs/LICENSE.md" "$OUT/mermaid/LICENSE-elkjs.md"

# D2 and Graphviz are ES modules; wrap each as a classic script with one global.
mkdir -p "$OUT/d2" "$OUT/graphviz"
echo 'import { D2 } from "@terrastruct/d2"; window.QuireD2 = D2;' > "$WORK/d2-entry.js"
echo 'import { Graphviz } from "@hpcc-js/wasm-graphviz"; window.QuireGraphviz = Graphviz;' > "$WORK/graphviz-entry.js"
bun build "$WORK/d2-entry.js" --target=browser --format=iife --minify --outfile="$OUT/d2/d2.js" >/dev/null
bun build "$WORK/graphviz-entry.js" --target=browser --format=iife --minify --outfile="$OUT/graphviz/graphviz.js" >/dev/null
curl -fsSL "https://raw.githubusercontent.com/terrastruct/d2/master/LICENSE.txt" -o "$OUT/d2/LICENSE"
cp "$M/elkjs/LICENSE.md" "$OUT/d2/LICENSE-elkjs.md"
cp "$M/@hpcc-js/wasm-graphviz/LICENSE" "$OUT/graphviz/LICENSE"
curl -fsSL "https://gitlab.com/graphviz/graphviz/-/raw/main/LICENSE" -o "$OUT/graphviz/LICENSE-graphviz"

printf 'Mermaid %s, D2 %s, Graphviz (@hpcc-js/wasm-graphviz %s)\n' "$MERMAID" "$D2" "$GRAPHVIZ"
ls -l "$OUT/mermaid/mermaid.min.js" "$OUT/d2/d2.js" "$OUT/graphviz/graphviz.js"
