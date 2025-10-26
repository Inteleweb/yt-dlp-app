# yt-dlp Web UI for Raspberry Pi

Local network web interface. Backend runs on the Pi. Browser is UI only.

## 1) Install on Raspberry Pi

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip yt-dlp \
  lsblk util-linux coreutils
# optional codecs and ffmpeg for muxing:
sudo apt install -y ffmpeg