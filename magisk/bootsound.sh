#!/system/bin/sh
# Magisk post-fs-data.d hook (installed as /data/adb/post-fs-data.d/bootsound.sh).
#
# The boot animation's audio init (frameworks/base/cmds/bootanimation/audioplay.cpp
# InitAudioThread) skips audio.wav for the whole boot if checkService("audio")
# fails. On this ROM it fails for two reasons: SELinux denies the lookup (fixed
# below), and the animation starts ~4.5 s after power-on, before the service exists.
#
# Fix: as soon as the audio service is registered, and only if the animation is
# still running and boot hasn't completed, restart bootanim once. The new
# instance finds the audio service and plays the sound in sync with part0.
# Runs in the background so it never blocks Magisk's post-fs-data stage.
D=/data/adb/pixelsrv
LOG=$D/bootsound.log

# The real blocker: LineageOS 22.2 sepolicy lacks this rule, so bootanim's
# checkService("audio") is denied (avc: denied { find } ... name=audio
# scontext=u:r:bootanim:s0 tcontext=u:object_r:audio_service:s0) and it reports
# "Audio service is not ready yet" forever. Grant only that lookup.
/data/adb/magisk/magiskpolicy --live "allow bootanim audio_service service_manager find" \
  && echo "$(date '+%F %T') sepolicy: bootanim may now find audio_service" >> $LOG

# diagnostics: capture bootanimation/audio logs live (logd drops lines during boot)
logcat -b main -v time BootAnimation:V audioplay:V libOpenSLES:V AudioTrack:W '*:S' \
  > $D/bootanim-live.log 2>&1 &
LC=$!

(
  i=0
  while [ $i -lt 300 ]; do                       # give up after ~60 s
    [ "$(getprop sys.boot_completed)" = 1 ] && break
    if service check audio 2>/dev/null | grep -q ": found"; then
      echo "$(date '+%F %T') audio ready after ${i} checks; bootanim=$(getprop init.svc.bootanim)" \
        "play_sound=[$(getprop persist.sys.bootanim.play_sound)] reason=[$(getprop ro.boot.bootreason)]" \
        "powerctl=[$(getprop sys.powerctl)] boot_completed=[$(getprop sys.boot_completed)]" >> $LOG
      if [ "$(getprop init.svc.bootanim)" = running ]; then
        setprop ctl.restart bootanim
        echo "$(date '+%F %T') restarted bootanim" >> $LOG
        for t in 2 5; do
          sleep $((t == 2 ? 2 : 3))
          dumpsys media.audio_flinger > $D/af-after-${t}s.txt 2>&1
        done
      fi
      break
    fi
    i=$((i + 1))
    sleep 0.2
  done
  sleep 20; kill $LC 2>/dev/null
) &
