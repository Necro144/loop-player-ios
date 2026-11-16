#!/bin/bash
# Makes a small test library: tagged songs with and without artwork, untagged files
# in subfolders (one with "Artist - Title" in the name), and a short video.
set -e
OUT="$1"
mkdir -p "$OUT/Sub Folder/Deeper"
cd "$OUT"
ffmpeg -loglevel error -y -f lavfi -i "color=c=0xff4478:s=600x600" -frames:v 1 cover.png
ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=440:duration=30" -i cover.png -map 0 -map 1 \
  -c:a libmp3lame -b:a 192k -c:v mjpeg -id3v2_version 3 \
  -metadata title="Night Drive" -metadata artist="Necro" -metadata album="CI Album" \
  -metadata:s:v title="Album cover" -metadata:s:v comment="Cover (front)" -disposition:v attached_pic "night.mp3"
ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=660:duration=25" -c:a aac -b:a 256k \
  -metadata title="Second Song" -metadata artist="Necro" -metadata album="CI Album" "second.m4a"
ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=330:duration=12" "Sub Folder/Necro - Lost Signal.wav"
ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=550:duration=15" "Sub Folder/Deeper/01 - Untagged Flac.flac"
ffmpeg -loglevel error -y -f lavfi -i "testsrc=size=640x360:rate=30:duration=20" -f lavfi -i "sine=frequency=500:duration=20" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest -metadata title="Clip Video" -metadata artist="Necro" "clip.mp4"
# A longer song video that starts on black (like many song videos): the picture must skip the black.
ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=10:duration=120" -f lavfi -i "sine=frequency=420:duration=120"   -vf "fade=t=in:st=4:d=0.5" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest   -metadata title="Long Song Video" -metadata artist="Necro" "Long Song Video.mp4"
rm cover.png
find . -type f -exec ls -l {} \;
