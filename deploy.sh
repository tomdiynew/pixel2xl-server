#!/usr/bin/env bash
# Deploy to the Pixel 2 XL (taimen, LineageOS 22.2 + Magisk).
#
#   ./deploy.sh root      root services -> /data/adb (needs USB + adb root)
#   ./deploy.sh bootanim  boot animation -> /product/media (needs USB, adb remount)
#   ./deploy.sh web       dashboard, boot intro, Termux settings (over SSH)
#   ./deploy.sh all
#   ./deploy.sh status
set -euo pipefail
cd "$(dirname "$0")"
PHONE="${PHONE:-192.168.43.202}"
SSH=(ssh -p 8022 -o ConnectTimeout=8 "$PHONE")
BOOTANIM="${BOOTANIM:-/Volumes/SSD1G/download/pixel2xl-lineage/bootanimation-pixel.zip}"

adb_root() { adb root >/dev/null; sleep 2; adb wait-for-device; }

root() {
  adb_root
  adb shell 'mkdir -p /data/adb/pixelsrv /data/adb/service.d'
  adb push magisk/phonectl.sh magisk/termux-services.sh magisk/termux-intro.sh /data/adb/pixelsrv/ >/dev/null
  adb push magisk/service.sh /data/adb/service.d/pixelsrv.sh >/dev/null
  adb shell 'mkdir -p /data/adb/post-fs-data.d'
  adb push magisk/bootsound.sh /data/adb/post-fs-data.d/bootsound.sh >/dev/null
  adb shell 'chmod 755 /data/adb/service.d/pixelsrv.sh /data/adb/post-fs-data.d/bootsound.sh /data/adb/pixelsrv/*.sh
    settings put global stay_on_while_plugged_in 3
    locksettings set-disabled true >/dev/null
    dumpsys deviceidle whitelist +com.termux >/dev/null
    ls -l /data/adb/service.d /data/adb/post-fs-data.d /data/adb/pixelsrv'
  echo "root services installed; they start at next boot"
}

bootanim() {
  # Magisk modules mount too late (after /data) for bootanim, which starts ~4.5 s
  # after power-on; write the zip straight into /product via adb remount instead
  # (userdebug build, verity disabled by Magisk's patched boot).
  adb_root
  [ -f "$BOOTANIM" ] || { echo "missing $BOOTANIM (build with: W=1440 H=2880 tools/build_bootanim.sh ...)"; exit 1; }
  adb remount >/dev/null
  BK="$(dirname "$BOOTANIM")/backup/bootanimation-lineage22-stock.zip"
  if [ ! -f "$BK" ]; then mkdir -p "$(dirname "$BK")"; adb pull /product/media/bootanimation.zip "$BK" >/dev/null; echo "stock animation backed up to $BK"; fi
  adb shell 'rm -rf /data/adb/modules/customboot'
  adb push "$BOOTANIM" /system/product/media/bootanimation.zip >/dev/null
  adb shell 'chmod 644 /system/product/media/bootanimation.zip; chown root:root /system/product/media/bootanimation.zip
    restorecon /system/product/media/bootanimation.zip 2>/dev/null; sync; md5sum /product/media/bootanimation.zip'
  md5 -q "$BOOTANIM"
  echo "boot animation installed; active from next boot"
}

web() {
  "${SSH[@]}" 'mkdir -p ~/webstat ~/bin ~/.termux ~/.config/neofetch'
  scp -q -P 8022 termux/webstat/server.py termux/webstat/index.html "$PHONE":webstat/
  scp -q -P 8022 termux/bin/boot-intro "$PHONE":bin/
  scp -q -P 8022 termux/dot-termux/termux.properties "$PHONE":.termux/termux.properties
  "${SSH[@]}" 'chmod 700 ~/bin/boot-intro ~/webstat/server.py
    [ -s ~/.config/neofetch/config.conf ] || neofetch --print_config > ~/.config/neofetch/config.conf 2>/dev/null
    sed -i "s/^ascii_distro=.*/ascii_distro=\"android_small\"/" ~/.config/neofetch/config.conf
    pkill -f "python3 .*webstat/[s]erver.py"; echo "dashboard restarting (supervisor relaunches it within 30s)"'
  # Cloudflare tunnel -> https://pixel.tomexp.com. The credentials JSON stays on the phone.
  # cloudflared is missing on the packages-cf mirror, so use the same mirror as the Redmi.
  "${SSH[@]}" 'mkdir -p ~/.cloudflared; command -v cloudflared >/dev/null || {
      echo "deb https://ftp.agdsn.de/termux/termux-main stable main" > $PREFIX/etc/apt/sources.list
      apt update >/dev/null 2>&1; apt install -y cloudflared >/dev/null 2>&1; }'
  scp -q -P 8022 termux/cloudflared/config.yml "$PHONE":.cloudflared/config.yml
  "${SSH[@]}" 'pkill -f "bin/[c]loudflared " || true'   # pixelsrv (ROM) restarts it within 30 s
}

case "${1:-}" in
  root) root ;;
  bootanim) bootanim ;;
  web) web ;;
  all) root; bootanim; web ;;
  status)
    adb shell 'tail -n 3 /data/adb/pixelsrv/phonectl.log; ls /data/adb/modules' 2>/dev/null || true
    "${SSH[@]}" 'pgrep -fa "[s]shd$|[w]ebstat"; tail -n 2 ~/webstat.log' ;;
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
