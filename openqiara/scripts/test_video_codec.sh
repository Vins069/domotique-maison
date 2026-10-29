#!/bin/sh
# Test of the video settings read by camera_boot.sh (OpenQIARA Claude V15): the lines between the
# « video settings » markers are replayed against test configuration files.
# Usage: sh scripts/test_video_codec.sh [shell]   (e.g. "busybox sh"); exit status 0 when everything passes.
SH=${1:-sh}
cd "$(dirname "$0")" || exit 1
snippet=$(sed -n '/^# >>> video settings/,/^# <<< video settings/p' camera_boot.sh)
[ -n "$snippet" ] || { echo "FAIL: markers missing from camera_boot.sh"; exit 1; }
d=$(mktemp -d) || exit 1
trap 'rm -rf "$d"' EXIT
fail=0
run() { OQ_CONFIG=$1 $SH -c "$snippet
echo \"\$CODEC|\$IV|\$VIDEO_OPTS\""; }
check() { # check expected json
    printf '%s' "$2" > "$d/openqiara.json"
    got=$(run "$d/openqiara.json")
    if [ "$got" = "$1" ]; then echo "  ok  : $1 <- $2"; else echo "  FAIL: $got (expected $1) <- $2"; fail=1; fi
}
check 'h264|1|' '{}'
check 'h264|1|' '{"video":{"lock":false}}'
check 'h264|1|' '{"video":{"codec":"h264"}}'
check 'h265|1|' '{"video":{"codec":"h265"}}'
check 'h265|1|' '{"video": { "codec" : "H265" }}'
check 'h265|1|' '{"video":{"codec":"hevc"}}'
check 'h265|1|' '{"video":{"codec":"H.265"}}'
check 'h264|1|' '{"video":{"codec":"mpeg2"}}'
check 'h264|1|' '{"video":{"codec":"h2650"}}'
check 'h264|1|' 'damaged file {{{'
check 'h265|1| --1080p-bitrate 2500000 --gop-denum 1' '{"video":{"codec":"h265","bitrate":2500000,"gop_denum":1}}'
check 'h265|0| --1080p-bitrate 2500000 --gop-denum 1' '{
  "video": {
    "codec": "h265",
    "bitrate": 2500000,
    "gop_denum": 1,
    "iv_detection": false
  }
}'
check 'h264|1|' '{"video":{"bitrate":90000000,"gop_denum":0}}'
check 'h264|1|' '{"video":{"bitrate":100,"gop_denum":31}}'
check 'h264|1| --gop-denum 2' '{"video":{"bitrate":"fast","gop_denum":2}}'
check 'h264|1|' '{"video":{"iv_detection":true}}'
got=$(run "$d/absent.json")
if [ "$got" = 'h264|1|' ]; then echo "  ok  : h264|1| <- no file"; else echo "  FAIL: $got <- no file"; fail=1; fi
[ "$fail" = 0 ] && echo "video settings: all pass ($SH)"
exit $fail
