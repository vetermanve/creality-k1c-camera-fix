# Creality K1C: restoring the MJPEG camera stream on firmware 1.3.5.22

[Русская версия](README.ru.md)

After updating a Creality K1C to firmware **1.3.5.22**, the built-in camera disappears from
the printer's own web interface, from Fluidd and Mainsail, and from the OrcaSlicer "Device" tab.

The camera hardware is fine. Creality commented out the line that publishes the MJPEG stream.

## Symptoms

- The printer's own web UI (`http://<printer-ip>/`) shows the placeholder
  *"Please check — Does the printer camera device work properly."*
- Port `8080` on the printer is closed, so `http://<printer-ip>:8080/?action=stream` is unreachable.
- Fluidd, Mainsail, OrcaSlicer, Obico and OctoEverywhere show no camera.
- The printer still reports `video = 1` over its WebSocket API, and there is no error in `err`.

OrcaSlicer is a red herring here. Its "Device" tab simply embeds the printer's own web UI,
so it fails for exactly the same reason. There is nothing to configure in the slicer.

## Diagnosis

Scanning the printer shows only ports `80` (legacy web UI), `443`, `8000` and `9999`
(Creality's own WebSocket API) open. `4408` (Fluidd), `7125` (Moonraker), `8080` (MJPEG) are closed.

Over SSH:

```
$ ps w | grep -i cam
1094 root 7:36 /usr/bin/cam_app -i /dev/v4l/by-id/main-video-4 -t 0 -w 1280 -h 720 -f 15 -c

$ ps w | grep -iE "webrtc|mjpg"
1539 root 0:37 /usr/bin/webrtc 2877642805CD81 2
1542 root 0:11 /usr/bin/webrtc_local
```

So `cam_app` is running and holding the V4L2 device, `webrtc` is running, and `mjpg_streamer`
is not running at all.

The camera is started by `/usr/bin/auto_uvc.sh`, triggered by a udev rule in
`/etc/udev/rules.d/60-persistent-v4l.rules`. That script is also supposed to start
`mjpg_streamer` — it even defines `MAIN_PORT=8080` at the top. But the launch itself is
commented out:

```sh
            sleep 1

#            LD_LIBRARY_PATH=/usr/lib/mjpg-streamer/ \
#            start-stop-daemon -S -b -m -p /var/run/$1_mjpg.pid \
#                --exec $MJPG_STREAMER -- -i "input_memfd.so -t $MAIN_CAM" \
#                -o "output_http.so -w /usr/share/mjpg-streamer/www/ -p $MAIN_PORT"
```

That is the whole bug. Creality moved the camera to `cam_app` plus their own WebRTC service
for Creality Print and Creality Cloud, dropped the MJPEG bridge, and left the bundled web UI
still pointing at port 8080. The web UI bundle on the printer is hardcoded to

```js
`http://${ip}:8080/?action=stream`
```

and has no other source of frames, so it falls back to the placeholder.

### Why `input_uvc.so` is not the answer

`cam_app` holds `/dev/v4l/by-id/main-video-4` and frames are handed out through memfd
(`libmemfd.so`, `memfd_client_init`), not through the V4L2 node. The shipped
`input_memfd.so` plugin attaches to `cam_app` as a memfd client:

```
$ strings /usr/lib/mjpg-streamer/input_memfd.so | grep -i help -A2
 Help for input plugin..: MEMFD input plugin
 [-t | --type ]........: camera type, main: 0, sub: 1
```

This also matches the command Creality themselves commented out. Note that it takes no device
path and no resolution — only the camera index.

Some reports on the Creality forum describe waiting for `/dev/shm/camera_main` to appear.
On 1.3.5.22 that file does not exist; `input_memfd.so` talks to `cam_app` directly, so the
correct dependency to wait for is the `cam_app` process itself.

## The fix

Run `mjpg_streamer` with the `input_memfd.so` plugin, using the same arguments as the
commented-out stock command, from an init script so it survives reboots:

```sh
/usr/bin/mjpg_streamer -b \
  -i "/usr/lib/mjpg-streamer/input_memfd.so -t 0" \
  -o "/usr/lib/mjpg-streamer/output_http.so -w /usr/share/mjpg-streamer/www/ -p 8080"
```

[`S59mjpg_streamer`](S59mjpg_streamer) wraps this with a wait for `cam_app`, because `cam_app`
is started by udev when the camera is enumerated, not in init-script order.

### Install

Root access is required. On the printer's touchscreen: **gear icon → Root account information**,
scroll the disclaimer to the bottom, tick the checkbox, press **Next Step**, wait about 30 seconds.
Default credentials are `root` / `creality_2023`.

Note: some 2025 hardware revisions of the K1C no longer offer this menu item.

```sh
./install.sh <printer-ip>
```

Or manually:

```sh
scp -O S59mjpg_streamer root@<printer-ip>:/etc/init.d/S59mjpg_streamer
scp -O S59mjpg_streamer root@<printer-ip>:/usr/data/S59mjpg_streamer
ssh root@<printer-ip> 'chmod +x /etc/init.d/S59mjpg_streamer /usr/data/S59mjpg_streamer'
ssh root@<printer-ip> '/etc/init.d/S59mjpg_streamer start'
```

`scp -O` is required: the printer runs dropbear without an sftp server.

The copy in `/usr/data/` is there because a firmware update wipes `/etc`. After an update,
restore it with:

```sh
ssh root@<printer-ip> 'cp /usr/data/S59mjpg_streamer /etc/init.d/ && /etc/init.d/S59mjpg_streamer start'
```

`/etc/init.d/rcS` iterates over `/etc/init.d/S??*` and calls each with `start`, so the script
runs at boot without further registration.

### Verify

```sh
curl -o /dev/null -w '%{http_code} %{content_type}\n' 'http://<printer-ip>:8080/?action=snapshot'
# 200 image/jpeg

curl -o /dev/null -w '%{http_code} %{content_type}\n' 'http://<printer-ip>:8080/?action=stream'
# 200 multipart/x-mixed-replace;boundary=boundarydonotcross
```

Then reload the printer's web UI. The camera appears with no further configuration, and the
OrcaSlicer "Device" tab picks it up because it embeds that same UI.

For Fluidd or Mainsail, set the webcam URL to `http://<printer-ip>:8080/?action=stream`
with service type `MJPEG-Streamer`.

### Uninstall

```sh
ssh root@<printer-ip> '/etc/init.d/S59mjpg_streamer stop; rm -f /etc/init.d/S59mjpg_streamer /usr/data/S59mjpg_streamer'
```

## Notes and caveats

- Enabling root is an official, documented function of the printer's own menu, not an exploit,
  but you accept a disclaimer to do it. That is your decision to make.
- This does not patch `/usr/bin/auto_uvc.sh`. A separate init script is cleaner and easier to
  revert, and the patched file would be overwritten by the next firmware update anyway.
- `cam_app`, the WebRTC services and Creality Print keep working. The script only adds a second
  consumer of the same frames.
- Running `mjpg_streamer` does not touch Klipper. It is safe to install while a print is running.

## Tested on

- Creality K1C, `DWIN sw ver 1.3.5.22`, kernel `Linux 4.4.94 mips`
- Camera `1280x720 @ 15fps` on `/dev/v4l/by-id/main-video-4`
- Verified: stream and snapshot endpoints, the printer's own web UI, the OrcaSlicer Device tab,
  and restart through the init script
- Boot persistence verified by a full reboot: with `uptime` at 0 minutes `mjpg_streamer` was
  already running and the stream was available, with no manual step

Note that the printer takes several minutes to come back after `reboot` before SSH and the
web interface answer again. That is normal, the camera is up as soon as they are.

## References

- [Creality forum: K1C firmware 1.3.5.22 — internal camera working again in Mainsail/Fluidd](https://forum.creality.com/t/solved-k1c-firmware-1-3-5-22-internal-camera-working-again-in-mainsail-fluidd/52668)
- [Creality Helper Script Wiki: discussion on firmware 1.3.5.22](https://github.com/Guilouz/Creality-Helper-Script-Wiki/discussions/901)

## License

MIT
