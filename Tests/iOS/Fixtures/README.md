# Mobile player fixtures

`player-fixture-01.mp4` and `player-fixture-02.mp4` are identical original 90-second FFmpeg test patterns with a quiet synthetic tone and two embedded `mov_text` subtitle tracks. They contain no third-party media. Separate URLs exercise queue replacement and time reset. The two `.srt` files are the source subtitles and can also test external subtitle import. `player-fixture.xml` contains six original Bilibili-format comments, including one keyword filter candidate and all three supported display modes.

The Debug-only UI-test launch path uses this media with the actual libmpv engine. A test launch must never substitute a mock clock, duration, tracks, or playback state. Release builds exclude the `player-fixture*` resources.

Regenerate the MP4 from this directory with FFmpeg:

```sh
ffmpeg -y -f lavfi -i 'testsrc=size=320x180:rate=10:duration=90' -f lavfi -i 'sine=frequency=440:sample_rate=22050:duration=90' -i player-fixture-en.srt -i player-fixture-zh-Hant.srt -map 0:v -map 1:a -map 2:s -map 3:s -c:v libx264 -preset veryslow -crf 35 -pix_fmt yuv420p -c:a aac -b:a 16k -af volume=0.1 -c:s mov_text -metadata:s:s:0 language=eng -metadata:s:s:0 title=English -metadata:s:s:1 language=zho -metadata:s:s:1 title='Traditional Chinese' -movflags +faststart -t 90 player-fixture-01.mp4
cp player-fixture-01.mp4 player-fixture-02.mp4
```
