"""Generate actual media for HLS boundary regressions; never download network fixtures."""
import pathlib
import re
import shutil
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=True)
ffmpeg = shutil.which("ffmpeg")
if not ffmpeg:
    raise SystemExit("Install FFmpeg before running W6 downloads.")
(root / "blob").write_bytes(bytes(range(256)) * 32768)
source = root / "source.mp4"


def run(*args):
    subprocess.run([ffmpeg, "-nostdin", "-v", "error", "-y", *args], check=True)


run("-f", "lavfi", "-i", "testsrc2=size=160x90:rate=10", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
    "-t", "6", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "10", "-c:a", "aac", str(source))
for name in ("aes", "fmp4", "range", "master"):
    (root / name).mkdir(exist_ok=True)
key = root / "aes/key.bin"
key.write_bytes(bytes(range(16)))
key_info = root / "aes/key-info"
key_info.write_text("key.bin\n" + str(key) + "\n")
common = ["-i", str(source), "-c", "copy", "-hls_time", "1", "-hls_list_size", "0", "-hls_playlist_type", "vod"]
run(*common, "-start_number", "7", "-hls_key_info_file", str(key_info), str(root / "aes/index.m3u8"))
aes = root / "aes/index.m3u8"
aes.write_text(re.sub(r",IV=0x[0-9a-fA-F]+", "", aes.read_text()))
run(*common, "-hls_segment_type", "fmp4", str(root / "fmp4/index.m3u8"))
run(*common, "-hls_flags", "single_file", str(root / "range/index.m3u8"))
range_file = root / "range/index.m3u8"
lines, first = [], True
for line in range_file.read_text().splitlines():
    if line.startswith("#EXT-X-BYTERANGE:"):
        if not first:
            line = line.split("@")[0]
        first = False
    lines.append(line)
range_file.write_text("\n".join(lines) + "\n")
run(*common, "-an", str(root / "master/video.m3u8"))
run(*common, "-vn", str(root / "master/audio.m3u8"))
(root / "master/index.m3u8").write_text(
    '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="default",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=160x90,CODECS="avc1.64000a,mp4a.40.2",AUDIO="aac"\nvideo.m3u8\n')
