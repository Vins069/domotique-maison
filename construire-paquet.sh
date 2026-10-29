#!/bin/sh
# construire-paquet.sh : fabrique le paquet pret a l'emploi « OpenQIARA-Claude-V15 » (dossier + archive zip).
#   sh construire-paquet.sh [date AAAA-MM-JJ]       sortie : build/paquet/OpenQIARA-Claude-V15/ (dossier de travail), puis
#                                                   paquet/OpenQIARA-Claude-V15.zip et son empreinte (versionnes)
# Etapes : compilation reproductible du binaire ARM (Go 1.26.1, zig 0.17.0), version compacte (UPX 4), outils QIARA Plus
# (qiara-plus/build.sh), assemblage, empreintes. Prerequis : go, python3 -m ziglang, upx, zip.
set -e
ICI=$(cd "$(dirname "$0")" && pwd)
DATE=${1:-$(date +%Y-%m-%d)}
OUT=$ICI/build/paquet/OpenQIARA-Claude-V15
rm -rf "$ICI/build/paquet"; mkdir -p "$OUT/camera" "$OUT/home-assistant" "$ICI/paquet"
echo "== binaire ARM"
sh "$ICI/openqiara/scripts/build-arm.sh" v15 "$DATE" "$OUT/camera/openqiarad-claude-v15"
cp "$OUT/camera/openqiarad-claude-v15" "$OUT/camera/openqiarad-claude-v15-compact"
upx -q --best --lzma "$OUT/camera/openqiarad-claude-v15-compact" >/dev/null
echo "== QIARA Plus v10"
sh "$ICI/qiara-plus/build.sh" >/dev/null
cp "$ICI/qiara-plus/dist/qp-setup.sh" "$OUT/camera/"
echo "== scripts"
cp "$ICI/openqiara/scripts/camera_boot.sh" "$OUT/camera/boot.sh"
cp "$ICI/camera/oqc/installer.sh" "$ICI/camera/oqc/services-cloud.sh" "$ICI/camera/oqc/reglage.sh" "$OUT/camera/"
chmod 755 "$OUT/camera/"*
for f in "$OUT/camera/"*.sh; do sh -n "$f" || { echo "syntaxe : $f"; exit 1; }; done
cp "$ICI/installation/configuration.txt" "$ICI/installation/commun.sh" "$ICI/installation/preparer-carte-sd.sh" "$ICI/installation/mettre-a-niveau.sh" "$OUT/"
cp "$ICI/installation/"*.ps1 "$OUT/" 2>/dev/null || true
chmod 755 "$OUT/preparer-carte-sd.sh" "$OUT/mettre-a-niveau.sh"
cp -r "$ICI/home-assistant/." "$OUT/home-assistant/" 2>/dev/null || true
cp "$ICI/LISEZ-MOI.md" "$OUT/" 2>/dev/null || true
cp "$ICI/LICENSE" "$OUT/" 2>/dev/null || true
( cd "$OUT/camera" && sha256sum * | grep -v ' SHA256SUMS$' > SHA256SUMS )
( cd "$OUT" && find . -type f ! -name SHA256SUMS-PAQUET | sort | xargs sha256sum > SHA256SUMS-PAQUET )
( cd "$ICI/build/paquet" && rm -f OpenQIARA-Claude-V15.zip && zip -qr -X OpenQIARA-Claude-V15.zip OpenQIARA-Claude-V15 )
cp "$ICI/build/paquet/OpenQIARA-Claude-V15.zip" "$ICI/paquet/OpenQIARA-Claude-V15.zip"
( cd "$ICI/paquet" && sha256sum OpenQIARA-Claude-V15.zip > OpenQIARA-Claude-V15.zip.sha256 )
echo "== paquet"
ls -la "$OUT" "$OUT/camera"
sha256sum "$ICI/paquet/OpenQIARA-Claude-V15.zip"
