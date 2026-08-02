# Развёртывание на публичном сервере

Как поднять Frogster на VPS с белым IP и раздать клиентов тестировщикам.
Проверено на Debian/Ubuntu, 2 августа 2026.

Для локального теста «ПК + телефон в одной Wi-Fi» это не нужно — там проще,
см. [TESTING.md](TESTING.md).

---

## Часть 0. Что понадобится

- VPS с белым IP и root-доступом
- Docker и Docker Compose на нём
- Go 1.25+ — либо на сервере, либо кросс-компиляция с рабочей машины (см. 1Б)

Дальше по тексту `186.246.9.163` — пример. Подставляйте свой адрес.

---

## Часть 1А. Собрать серверы на VPS

```bash
cd ~/FrogsterMessenger/server
go build -o /usr/local/bin/frogsterd ./cmd/frogsterd
go build -o /usr/local/bin/filed ./cmd/filed
```

**Если сборка падает с `compile: signal: killed`** — это OOM-killer, компилятору
не хватило памяти. Проверить: `dmesg | tail -20 | grep -i "killed process"`.

Лечится swap-файлом:

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab   # переживёт ребут
```

Дополнительно помогает `go build -p 1` — компилировать пакеты по одному.
Медленнее, но пик потребления заметно ниже.

## Часть 1Б. Либо собрать у себя и залить

Go кросс-компилируется, тулчейн на сервере тогда не нужен вовсе:

```powershell
$env:GOOS="linux"; $env:GOARCH="amd64"
cd server
go build -o frogsterd-linux ./cmd/frogsterd
go build -o filed-linux ./cmd/filed
```

Дальше `scp` на сервер, `chmod +x`, положить в `/usr/local/bin/`.

---

## Часть 2. Инфраструктура

```bash
cd ~/FrogsterMessenger
docker compose -f deploy/docker-compose.yml up -d
docker compose -f deploy/docker-compose.yml ps
```

Дождитесь, пока оба контейнера станут `healthy`. Postgres на 5432, Redis на
**16379** (не 6379 — так в compose-файле).

**Наружу их не открывать.** Пароль в `deploy/docker-compose.yml` — дефолтный
`frogster/frogster`. На публичной машине стоит заменить проброс на loopback:
`"127.0.0.1:5432:5432"`.

---

## Часть 3. Переменные окружения

Секрет генерируется прямо при записи файла — копировать его никуда не нужно:

```bash
sudo tee /etc/frogster.env >/dev/null <<EOF
FROGSTER_ENV=prod
FROGSTER_JWT_SECRET=$(openssl rand -base64 48)
FROGSTER_ADDR=0.0.0.0:18080
FROGSTER_FILED_ADDR=0.0.0.0:18081
FROGSTER_DATABASE_URL=postgres://frogster:frogster@localhost:5432/frogster?sslmode=disable
FROGSTER_REDIS_URL=redis://localhost:16379/0
FROGSTER_BLOB_DIR=/var/lib/frogster/blobs
EOF

sudo chmod 600 /etc/frogster.env
sudo mkdir -p /var/lib/frogster/blobs
```

Три вещи, которые легко испортить:

- **`FROGSTER_ENV=prod` обязательно.** В `dev` подставляется захардкоженный в
  исходниках JWT-секрет (`server/internal/config/config.go`), и на публичном
  адресе любой, кто видел репозиторий, сможет подписать себе токен. В `prod`
  сервер требует свой секрет от 32 байт и без него не стартует.
- **`0.0.0.0`, а не `:18080`.** Иначе слушает только localhost и снаружи будет
  `Connection refused`.
- **Redis на 16379.** Дефолт в коде — 6379. С неверным портом сервер
  запустится, но напишет `redis unavailable`, и лимиты станут попроцессными.

Проверить, что файл записался и секрет подставился:

```bash
sudo cat /etc/frogster.env
```

---

## Часть 4. Первый запуск — в переднем плане

Чтобы увидеть ошибки, если они есть:

```bash
set -a && source /etc/frogster.env && set +a
/usr/local/bin/frogsterd
```

Ожидаемый вывод — миграции применяются автоматически, отдельный шаг не нужен:

```
"msg":"starting frogsterd","env":"prod","addr":"0.0.0.0:18080"
"msg":"migration applied","file":"0001_init.sql"
"msg":"migration applied","file":"0002_ed25519_identity.sql"
"msg":"connected to redis"
"msg":"http server listening","addr":"0.0.0.0:18080"
```

Проверить из второй SSH-сессии: `curl -v http://127.0.0.1:18080/healthz`.
Работает — Ctrl+C и дальше.

---

## Часть 5. systemd

Без этого всё умрёт при выходе из SSH. Серверов **два**: `frogsterd` — текст,
`filed` — вложения. Без второго картинки ходить не будут.

```bash
sudo tee /etc/systemd/system/frogsterd.service >/dev/null <<'EOF'
[Unit]
Description=Frogster messaging server
After=network.target docker.service

[Service]
EnvironmentFile=/etc/frogster.env
ExecStart=/usr/local/bin/frogsterd
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/frogster-filed.service >/dev/null <<'EOF'
[Unit]
Description=Frogster file server
After=network.target docker.service

[Service]
EnvironmentFile=/etc/frogster.env
ExecStart=/usr/local/bin/filed
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now frogsterd frogster-filed
```

`enable --now` = запустить сейчас + автозапуск после ребута.

### Управление

```bash
sudo systemctl stop frogsterd frogster-filed
sudo systemctl start frogsterd frogster-filed
sudo systemctl restart frogsterd frogster-filed
sudo systemctl disable frogsterd frogster-filed   # убрать из автозапуска
journalctl -u frogsterd -f                        # логи вживую
journalctl -u frogsterd -n 50 --no-pager          # последние 50 строк
```

Docker с postgres и redis живёт отдельно и выход из консоли переживает сам.

---

## Часть 6. Порты и проверка

```bash
sudo ufw allow 18080/tcp
sudo ufw allow 18081/tcp

ss -tlnp | grep -E "18080|18081"
```

В выводе `ss` должны быть **две** строки с `*:` или `0.0.0.0:`, а не
`127.0.0.1:`. Если `ufw status` показывает `inactive` — правила не нужны, но у
провайдера может быть своя security group в панели управления.

С рабочей машины:

```powershell
curl.exe -v http://186.246.9.163:18080/healthz
```

Ожидается `200 OK` и `{"status":"ok"}`.

**`Connection refused`** — порт дошёл, но никто не слушает: сервис не запущен
или слушает localhost. **Таймаут без ответа** — пакет дропнут, это firewall
или security group.

---

## Часть 7. Собрать клиентов

Адрес зашивается **на этапе сборки** (`String.fromEnvironment` в
`client/lib/app.dart`), в рантайме его сменить нельзя. Значит:

> Себе и тестировщику нужны билды с **одним и тем же** адресом. Иначе оба
> приложения работают, но вы в разных мирах и друг друга не видите.

### Перед сборкой APK — разрешить cleartext

Android 9+ блокирует HTTP без TLS. Адрес нужно вписать в
`client/android/app/src/main/res/xml/network_security_config.xml`:

```xml
<domain includeSubdomains="false">186.246.9.163</domain>
```

Это список разрешений, а не «текущий адрес» — старые записи можно оставить,
они не конфликтуют. CIDR не поддерживается, только точные литералы.

### APK

```powershell
cd client
flutter build apk --release --dart-define=FROGSTER_SERVER=http://186.246.9.163:18080 --dart-define=FROGSTER_FILE_HOST=186.246.9.163 --dart-define=FROGSTER_FILE_PORT=18081
```

Результат: `client\build\app\outputs\flutter-apk\app-release.apk` (~56 МБ).

Обратите внимание на формат: `FROGSTER_SERVER` — полный URL со схемой и портом,
`FROGSTER_FILE_HOST` — **только адрес, без `http://`**. Это отдельный gRPC-канал,
он собирает хост и порт сам. Со схемой вложения молча перестанут работать при
живом тексте.

### Windows

```powershell
flutter build windows --release --dart-define=FROGSTER_SERVER=http://186.246.9.163:18080 --dart-define=FROGSTER_FILE_HOST=186.246.9.163 --dart-define=FROGSTER_FILE_PORT=18081
```

Отдавать **всю папку** `client\build\windows\x64\runner\Release\`, а не один
`.exe` — без соседних DLL и `data\` он не запустится.

### Проверить, что адрес реально зашился

Сборка может занять три секунды за счёт кэша Gradle — это не значит, что
ничего не пересобралось. Надёжная проверка:

```powershell
python -c "import zipfile; z=zipfile.ZipFile('build/app/outputs/flutter-apk/app-release.apk'); b=z.read('lib/arm64-v8a/libapp.so'); print('new:', b.count(b'186.246.9.163'), 'old:', b.count(b'192.168.50.238'))"
```

Нужно ненулевое `new` и ноль в `old`.

---

## Часть 8. Что сказать тестировщику

- Разрешить установку из неизвестных источников для мессенджера, через который
  придёт файл
- Play Protect предупредит о неподписанном приложении — «Всё равно установить»
- На Windows SmartScreen скажет «Windows защитила ваш компьютер» → «Подробнее»
  → «Выполнить в любом случае»
- Регистрация внутри приложения, заводить аккаунт заранее не нужно
- Удаление на Android обычное: система сносит песочницу целиком, руками искать
  ничего не надо. На ПК — см. «Удалить следы после тестов» в
  [TESTING.md](TESTING.md)

---

## Известные ограничения этой схемы

**Трафик идёт по HTTP.** Тексты и вложения защищены сквозным шифрованием —
сервер и провайдер их не прочитают. Но **токен сессии передаётся открыто** и
перехватывается по пути; с ним можно выдать себя за пользователя на сервере.
Для теста в узком кругу приемлемо, для постоянной работы — нет.

Правильное решение: nginx с Let's Encrypt перед `frogsterd`, тогда в клиент
идёт `https://` и правка `network_security_config.xml` вообще не нужна.
С `filed` сложнее — это gRPC, ему нужен отдельный TLS-терминатор и
`secure: true` в `client/lib/data/remote/file_client.dart`.

**Пароль postgres дефолтный** (`frogster/frogster`). Пока порт не проброшен
наружу — не критично, но менять при первой возможности.

---

## Полный сброс сервера

```bash
sudo systemctl stop frogsterd frogster-filed
docker compose -f deploy/docker-compose.yml down -v
sudo rm -rf /var/lib/frogster/blobs/*
```

`-v` сносит тома `pgdata` и `redisdata` — вместе с ними уходят учётные записи,
публичные ключи и офлайн-очередь. Без `-v` старые аккаунты переживут
перезапуск и будут конфликтовать с новой регистрацией.

Клиентам после этого тоже нужен сброс, иначе они придут со старой identity к
серверу, который о ней не знает.
