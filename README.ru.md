# Creality K1C: возврат MJPEG-потока камеры на прошивке 1.3.5.22

[English version](README.md)

После обновления Creality K1C до прошивки **1.3.5.22** встроенная камера пропадает из
собственного веб-интерфейса принтера, из Fluidd и Mainsail, из вкладки "Device" в OrcaSlicer.

Камера при этом исправна. Creality закомментировала строку, публикующую MJPEG-поток.

## Симптомы

- Веб-морда принтера (`http://<ip-принтера>/`) показывает заглушку
  *"Please check — Does the printer camera device work properly."*
- Порт `8080` закрыт, `http://<ip-принтера>:8080/?action=stream` недоступен.
- Fluidd, Mainsail, OrcaSlicer, Obico и OctoEverywhere камеру не видят.
- Принтер по своему WebSocket API продолжает отдавать `video = 1`, ошибок в `err` нет.

OrcaSlicer тут ни при чём. Его вкладка "Device" просто встраивает ту же веб-морду принтера
и падает по той же причине. В слайсере настраивать нечего.

## Диагностика

Сканирование принтера показывает открытыми только `80` (старая веб-морда), `443`, `8000`
и `9999` (собственный WebSocket API Creality). Порты `4408` (Fluidd), `7125` (Moonraker)
и `8080` (MJPEG) закрыты.

По SSH:

```
$ ps w | grep -i cam
1094 root 7:36 /usr/bin/cam_app -i /dev/v4l/by-id/main-video-4 -t 0 -w 1280 -h 720 -f 15 -c

$ ps w | grep -iE "webrtc|mjpg"
1539 root 0:37 /usr/bin/webrtc 2877642805CD81 2
1542 root 0:11 /usr/bin/webrtc_local
```

То есть `cam_app` работает и держит V4L2-устройство, `webrtc` работает, а `mjpg_streamer`
не запущен вовсе.

Камеру поднимает `/usr/bin/auto_uvc.sh` по udev-правилу из
`/etc/udev/rules.d/60-persistent-v4l.rules`. Этот же скрипт должен запускать и
`mjpg_streamer` — в его шапке объявлен `MAIN_PORT=8080`. Но сам запуск закомментирован:

```sh
            sleep 1

#            LD_LIBRARY_PATH=/usr/lib/mjpg-streamer/ \
#            start-stop-daemon -S -b -m -p /var/run/$1_mjpg.pid \
#                --exec $MJPG_STREAMER -- -i "input_memfd.so -t $MAIN_CAM" \
#                -o "output_http.so -w /usr/share/mjpg-streamer/www/ -p $MAIN_PORT"
```

В этом вся суть. Creality перевела камеру на `cam_app` плюс собственный WebRTC-сервис для
Creality Print и Creality Cloud, мост в MJPEG убрала, а штатную веб-морду, которая ходит
на 8080, не тронула. Её бандл намертво зашит на

```js
`http://${ip}:8080/?action=stream`
```

другого источника кадров в нём нет, поэтому она показывает заглушку.

### Почему `input_uvc.so` не подходит

`cam_app` держит `/dev/v4l/by-id/main-video-4`, а кадры раздаёт через memfd
(`libmemfd.so`, `memfd_client_init`), а не через V4L2-узел. Штатный плагин `input_memfd.so`
цепляется к `cam_app` как memfd-клиент:

```
$ strings /usr/lib/mjpg-streamer/input_memfd.so | grep -i help -A2
 Help for input plugin..: MEMFD input plugin
 [-t | --type ]........: camera type, main: 0, sub: 1
```

Это совпадает с командой, которую Creality сама и закомментировала. Обрати внимание: плагин
не принимает ни путь к устройству, ни разрешение — только индекс камеры.

На форуме Creality встречается вариант скрипта, ожидающий появления `/dev/shm/camera_main`.
На 1.3.5.22 такого файла нет: `input_memfd.so` общается с `cam_app` напрямую, поэтому ждать
надо сам процесс `cam_app`.

## Решение

Запустить `mjpg_streamer` с плагином `input_memfd.so` ровно с теми аргументами, что были в
закомментированном штатном коде, и оформить это init-скриптом, чтобы переживало перезагрузку:

```sh
/usr/bin/mjpg_streamer -b \
  -i "/usr/lib/mjpg-streamer/input_memfd.so -t 0" \
  -o "/usr/lib/mjpg-streamer/output_http.so -w /usr/share/mjpg-streamer/www/ -p 8080"
```

[`S59mjpg_streamer`](S59mjpg_streamer) оборачивает это ожиданием `cam_app`, потому что тот
стартует по udev-событию при обнаружении камеры, а не по порядку init-скриптов.

### Установка

Нужен root. На экране принтера: **шестерёнка → Root account information**, прокрутить
дисклеймер до самого низа, поставить галочку, нажать **Next Step**, подождать около 30 секунд.
Учётные данные по умолчанию: `root` / `creality_2023`.

На части аппаратных ревизий K1C 2025 года этот пункт меню убран.

```sh
./install.sh <ip-принтера>
```

Либо вручную:

```sh
scp -O S59mjpg_streamer root@<ip-принтера>:/etc/init.d/S59mjpg_streamer
scp -O S59mjpg_streamer root@<ip-принтера>:/usr/data/S59mjpg_streamer
ssh root@<ip-принтера> 'chmod +x /etc/init.d/S59mjpg_streamer /usr/data/S59mjpg_streamer'
ssh root@<ip-принтера> '/etc/init.d/S59mjpg_streamer start'
```

Ключ `scp -O` обязателен: на принтере dropbear без sftp-сервера.

Копия в `/usr/data/` нужна потому, что обновление прошивки затирает `/etc`. После обновления
восстанавливается так:

```sh
ssh root@<ip-принтера> 'cp /usr/data/S59mjpg_streamer /etc/init.d/ && /etc/init.d/S59mjpg_streamer start'
```

`/etc/init.d/rcS` перебирает `/etc/init.d/S??*` и вызывает каждый с аргументом `start`,
поэтому скрипт отрабатывает при загрузке без дополнительной регистрации.

### Проверка

```sh
curl -o /dev/null -w '%{http_code} %{content_type}\n' 'http://<ip-принтера>:8080/?action=snapshot'
# 200 image/jpeg

curl -o /dev/null -w '%{http_code} %{content_type}\n' 'http://<ip-принтера>:8080/?action=stream'
# 200 multipart/x-mixed-replace;boundary=boundarydonotcross
```

Дальше обновить страницу веб-морды принтера. Камера появляется без какой-либо настройки,
вкладка "Device" в OrcaSlicer подхватывает её, потому что встраивает ту же морду.

Для Fluidd и Mainsail задать URL камеры `http://<ip-принтера>:8080/?action=stream`,
тип сервиса `MJPEG-Streamer`.

### Удаление

```sh
ssh root@<ip-принтера> '/etc/init.d/S59mjpg_streamer stop; rm -f /etc/init.d/S59mjpg_streamer /usr/data/S59mjpg_streamer'
```

## Замечания

- Включение root — штатная функция меню самого принтера, не эксплойт, но при включении
  принимается дисклеймер. Решение за владельцем.
- Файл `/usr/bin/auto_uvc.sh` не правится. Отдельный init-скрипт чище, легко откатывается,
  а правка штатного файла всё равно была бы затёрта следующим обновлением прошивки.
- `cam_app`, сервисы WebRTC и Creality Print продолжают работать. Скрипт лишь добавляет
  второго потребителя тех же кадров.
- `mjpg_streamer` не связан с Klipper. Устанавливать можно во время печати.

## Проверено на

- Creality K1C, `DWIN sw ver 1.3.5.22`, ядро `Linux 4.4.94 mips`
- Камера `1280x720 @ 15fps` на `/dev/v4l/by-id/main-video-4`
- Проверены: эндпоинты stream и snapshot, веб-морда принтера, вкладка Device в OrcaSlicer,
  перезапуск через init-скрипт
- Автозапуск следует из цикла `rcS` по `/etc/init.d/S??*`

## Ссылки

- [Форум Creality: K1C firmware 1.3.5.22 — internal camera working again in Mainsail/Fluidd](https://forum.creality.com/t/solved-k1c-firmware-1-3-5-22-internal-camera-working-again-in-mainsail-fluidd/52668)
- [Creality Helper Script Wiki: обсуждение прошивки 1.3.5.22](https://github.com/Guilouz/Creality-Helper-Script-Wiki/discussions/901)

## Лицензия

MIT
