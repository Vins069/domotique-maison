#!/bin/sh
# Construit les scripts autonomes de dist/ : chaque ligne "#@INCLUDE fichier" est remplacee par le contenu de src/fichier.
cd "$(dirname "$0")" || exit 1
mkdir -p dist
for f in src/*.sh; do
  b=$(basename "$f" .sh)
  [ "$b" = common ] && continue
  [ "$b" = setup ] && continue
  awk '/^#@INCLUDE /{ while ((getline l < ("src/" $2)) > 0) print l; close("src/" $2); next } { print }' "$f" > "dist/qp-$b"
  chmod 755 "dist/qp-$b"
  sh -n "dist/qp-$b" || { echo "ERREUR de syntaxe : dist/qp-$b"; exit 1; }
done
# installeur autonome : modele + outils encodes en base64 avec leurs empreintes
{
  cat tpl/setup.sh
  for t in qp-launch qp-guard qp-update; do
    echo "@@FILE $t $(sha256sum dist/$t | cut -d' ' -f1)"
    base64 dist/$t
  done
} > dist/qp-setup.sh
sh -n dist/qp-setup.sh || { echo "ERREUR de syntaxe : dist/qp-setup.sh"; exit 1; }
( cd dist && sha256sum qp-* > SHA256SUMS )
echo "construit :"; ls -la dist
