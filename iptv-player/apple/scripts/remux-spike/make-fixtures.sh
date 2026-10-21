#!/bin/sh
# Remux spike fixtures (Homebrew ffmpeg with libx264/libx265). usage: make-fixtures.sh <www dir with sintel.mkv>
# The 1080p/15 Mbit/s and no-cues files were added later:
#   ffmpeg -f lavfi -i "testsrc2=s=1920x1080:r=25,noise=alls=30:allf=t" -f lavfi -i "sine=f=600:r=48000" -t 120 \
#     -c:v libx264 -preset ultrafast -g 50 -b:v 15M -minrate 15M -maxrate 15M -bufsize 15M -pix_fmt yuv420p \
#     -c:a ac3 -ac 6 -b:a 448k remux-1080p-15mbps.mkv
#   ffmpeg -i remux-avsync.mkv -c copy -f matroska - > remux-nocues.mkv     (no cues → VLCKit fallback)
set -e
cd "$1"
F="ffmpeg -hide_banner -loglevel error -y"
# 1. H.264 + AAC stereo (sintel video copy, 180 s)
$F -i sintel.mkv -map 0:v:0 -map 0:a:0 -c:v copy -c:a aac -ac 2 -b:a 160k -metadata:s:a:0 language=eng remux-h264-aac.mkv
# 2. HEVC Main10 (x265 defaults: open GOP, B-pyramid) + E-AC-3 5.1
$F -i sintel.mkv -map 0:v:0 -map 0:a:0 -c:v libx265 -preset fast -pix_fmt yuv420p10le -crf 26 -x265-params log-level=error:keyint=96 -c:a eac3 -ac 6 -b:a 384k remux-hevc-eac3.mkv
# 3. H.264 + DTS 5.1 (needs audio transcode)
$F -i sintel.mkv -map 0:v:0 -map 0:a:0 -c:v copy -c:a dca -strict -2 -ac 6 -ar 48000 -b:a 768k remux-h264-dts.mkv
# 4. A/V sync clip: white flash (40 ms) + 1 kHz beep (40 ms) at every full second, 120 s, H.264 with B-frames
$F -f lavfi -i "color=c=black:s=1280x720:r=25,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='lt(mod(t\,1)\,0.04)'" \
   -f lavfi -i "sine=f=1000:r=48000,volume=volume=0:enable='gte(mod(t\,1)\,0.04)'" -t 120 \
   -c:v libx264 -preset veryfast -g 50 -bf 3 -pix_fmt yuv420p -c:a aac -b:a 128k -ac 2 remux-avsync.mkv
$F -i remux-avsync.mkv -map 0 -c:v copy -c:a dca -strict -2 -ar 48000 -ac 2 remux-avsync-dts.mkv
# 5. Long (45 min) 720p test pattern with a running counter, keyint 5 s, AAC
$F -f lavfi -i "testsrc=s=1280x720:r=25" -f lavfi -i "sine=f=440:r=48000:beep_factor=4" -t 2700 \
   -c:v libx264 -preset ultrafast -bf 0 -g 125 -b:v 700k -pix_fmt yuv420p -c:a aac -b:a 96k -ac 2 remux-long.mkv
ls -la remux-*
