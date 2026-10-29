#!/bin/sh
# Flux synthetiques des tests H.264 et H.265 (claude13) : mire ffmpeg de 3 s a 30 i/s en 160x90, une image cle toutes les
# 30 images, sans images B (GOP ferme, ordre de decodage = ordre d affichage, comme un encodeur de camera), delimiteurs d'unite d'acces inseres (le faux hlcamd s'en sert pour couper les images, puis les retire), en Annex B.
# Encodes en base64 (texte) : aucun binaire n'est commite. Les empreintes des flux decodes sont dans SHA256SUMS.
# Reproduction : sh gen.sh (ffmpeg 6.1 avec libx264 et libx265 ; un autre ffmpeg peut produire d'autres octets, les tests
# n'en dependent pas : ils lisent VPS/SPS/PPS, les images cles et les tranches, pas des octets precis).
set -e
cd "$(dirname "$0")"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=160x90:rate=30:duration=3" -pix_fmt yuv420p \
  -c:v libx265 -preset ultrafast -x265-params "keyint=30:min-keyint=30:scenecut=0:bframes=0:no-open-gop=1:log-level=none" \
  -bsf:v hevc_metadata=aud=insert -f hevc h265-testsrc.h265
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=160x90:rate=30:duration=3" -pix_fmt yuv420p \
  -c:v libx264 -preset ultrafast -profile:v baseline -x264-params "keyint=30:min-keyint=30:scenecut=0:bframes=0" \
  -bsf:v h264_metadata=aud=insert -f h264 h264-testsrc.h264
sha256sum h265-testsrc.h265 h264-testsrc.h264 > SHA256SUMS
base64 -w76 h265-testsrc.h265 > h265-testsrc.b64
base64 -w76 h264-testsrc.h264 > h264-testsrc.b64
rm -f h265-testsrc.h265 h264-testsrc.h264
echo "flux regeneres :"; cat SHA256SUMS
