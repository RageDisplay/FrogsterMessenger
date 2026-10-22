# Заметки для следующей сессии

Рабочий контекст проекта Frogster: что уже сделано, где закопаны грабли и как
поднять окружение. Не документация — она в [README.md](README.md),
[docs/crypto-protocol.md](docs/crypto-protocol.md) и [TESTING.md](TESTING.md).

## Состояние

Идёт доработка до прода в три этапа (план согласован с пользователем):

1. **Сервер в прод, деплой, TLS, сессии** — сделан. Ревью криптослоя
   ([docs/crypto-review-2026-10.md](docs/crypto-review-2026-10.md)),
   `deploy/install.sh`, обновление токенов, доставка с подтверждением клиента,
   адрес сервера и закрепление CA в приложении.
2. **Обычные (облачные) и секретные чаты, группы обоих видов** — сделан.
   Сервер: миграция 0004, `internal/storagecrypto`, облачная доставка без
   очереди (история — это очередь), события edit/delete/react с `seq`,
   кадры `skdm`/`read`/`chat_updated`, API групп, поиск, профиль. Клиент: БД v3
   (outbox, `sender_key_shares`), `GroupCipher`, синхронизация облака при
   каждом подключении, экраны «Новый чат», «Новая группа», «О группе», меню
   сообщения (реакции, копировать, изменить, удалить у всех, повторить),
   подгрузка истории, галочки прочтения.
3. **Редизайн, RU/EN, светлая/тёмная тема, функции, пуши (FCM на Android)**.

Платформы сейчас — Android и Windows; iOS будет нескоро, но Android-only кода
в общих слоях не заводить.

Клиент — 257 тестов (+ сквозной, без сервера пропускается), сервер — все
пакеты зелёные под `-race`, 4 Python E2E-скрипта — 48 проверок.

**Не сделано (из ревью):** Ed25519-ключ в TOFU-пине и safety number (#10, #11).

Клиентская логика чатов проверяется многоустройственными сценариями на
фейковом сервере в памяти: `client/test/data/fake_server.dart` +
`chats_test.dart` (настоящие движки, БД и репозитории).

**Git:** пользователь пушит сам на https://github.com/RageDisplay/FrogsterMessenger.
**Не создавать веток, не коммитить и не менять git-настройки без спроса.**
Работать в текущей ветке (`main`).

## Как поднять окружение

```bash
# 1. Инфраструктура. 5432 на этой машине в зарезервированном диапазоне Windows.
POSTGRES_PORT=15432 docker compose -f deploy/docker-compose.yml up -d   # postgres:15432, redis:16379

# 2. Серверы — процессами из bin/, не в докере
cd server && go build -o ../bin/frogsterd.exe ./cmd/frogsterd
go build -o ../bin/filed.exe ./cmd/filed
```

Переменные: `FROGSTER_ENV=dev`,
`FROGSTER_DATABASE_URL=postgres://frogster:frogster@localhost:15432/frogster?sslmode=disable`,
`FROGSTER_REDIS_URL=redis://localhost:16379/0`, `FROGSTER_ADDR=0.0.0.0:18080`,
`FROGSTER_FILED_ADDR=0.0.0.0:18081`. Логи: `bin/frogsterd.log`, `bin/filed.log`.

**Порты 18080/18081/16379/15432, а не стандартные**: Windows Hyper-V/WSL
резервирует диапазоны, Docker не может привязаться внутри них даже когда никто
не слушает. Проверка: `netsh interface ipv4 show excludedportrange protocol=tcp`.

### Тесты на этой машине

- `flutter test --no-pub` — без `--no-pub` падает: не включён Developer Mode
  (symlink). Сборки APK/Windows без Developer Mode не работают вообще —
  просить пользователя включить, самому настройки не трогать.
- `go test -race` локально не работает (нет cgo). Гонять в контейнере:
  `docker run --rm -v "$(pwd -W):/src" -w /src -v frogster-gomod:/go/pkg/mod -e FROGSTER_TEST_DATABASE_URL=postgres://frogster:frogster@host.docker.internal:15432/frogster?sslmode=disable golang:1.25.3 go test ./... -race`
  (из `server/`, в Git Bash с `MSYS_NO_PATHCONV=1`).
- Сквозной тест клиента против живого стека:
  `FROGSTER_E2E_SERVER=https://localhost FROGSTER_E2E_CA=<отпечаток> flutter test --no-pub test/integration/server_e2e_test.dart`.
- `install.sh` проверяется в привилегированном `ubuntu:24.04` с томом на
  `/var/lib/docker` (иначе overlay-on-overlay) и вручную запущенным `dockerd`
  (init-скрипт Docker в контейнере падает на `ulimit`). На настоящей Ubuntu
  этого не нужно.

### Сборка клиентов

Адрес сервера вводится в приложении и запоминается; в сборку он не вшивается.
Release ходит только по HTTPS; для dev-сервера без TLS — debug-сборка.

```bash
cd client
flutter build apk --debug --dart-define=FROGSTER_FILE_PORT=18081   # локальный dev-сервер
flutter build apk --release                                        # для сервера из install.sh
```

### Полный сброс для теста с нуля

```powershell
adb shell pm clear com.vectrixsecurity.frogster
Remove-Item "$env:APPDATA\Frogster" -Recurse -Force            # база ПК
Remove-Item "$env:APPDATA\com.vectrixsecurity" -Recurse -Force # ключи ПК!
```
```bash
docker compose -f deploy/docker-compose.yml exec -T postgres psql -U frogster -d frogster \
  -c "TRUNCATE users, devices, signed_pre_keys, one_time_pre_keys, chats, chat_members, messages, message_deliveries, group_sender_key_distributions, active_sessions RESTART IDENTITY CASCADE;"
docker compose -f deploy/docker-compose.yml exec -T redis redis-cli EVAL "local ks=redis.call('keys','frogster:*'); for i=1,#ks do redis.call('del',ks[i]) end; return #ks" 0
```

Обе папки на ПК обязательны. `%APPDATA%\com.vectrixsecurity` — это хранилище
`flutter_secure_storage` (файл `flutter_secure_storage.dat`), **не** Windows
Credential Manager. Без её удаления старая identity переживает «зачистку» и
симптомы возвращаются.

## Грабли, на которые уже наступали

Все перечисленные баги исправлены и закрыты тестами. Список нужен, чтобы не
чинить их заново и не ломать повторно.

### Крипта и доставка

| Симптом | Причина |
|---|---|
| После перезахода переписка рвётся, `MAC error` | Сервер не снимал доставку с очереди после live-отправки → сообщение приходило дважды. Ratchet-сообщение расшифровывается ровно один раз |
| Пишу первым — не доходит, а в обратную сторону работает | `_pendingHandshake` жил только в памяти. Перезапуск → prekey-материал терялся → уходило обычное `ct=2`, из которого собеседник не мог построить сессию |
| Собеседник перезашёл — сообщения не доходят | `key_change` приходил, но не сбрасывал кеш устройств в `DeviceResolver` |
| `device not addressed by sender, skipping` в логах | Отправитель шифрует по устаревшему списку устройств. Смотреть `per_device_payloads` в логе — если меньше числа активных устройств, это оно |
| Сообщения исчезали у получателя | FK `messages.chat_id` → нет строки чата. Лечится `_ensureChatExists` |
| Отзыв устройства не работал | `RevokeSession` отзывал только сессию, устройство оставалось активным в выдаче ключей |

### Окружение и сборка

| Симптом | Причина |
|---|---|
| «Could not reach the server» на телефоне, но `adb shell curl` проходит | В release-манифесте не было `android.permission.INTERNET` — Flutter добавляет его только в debug/profile |
| «Точно пересобрано? Время не меняется» | `frogster.exe` — только лаунчер, он и не меняется. Смотреть `build/windows/x64/runner/Release/data/app.so` |
| База на ПК не удалялась | `getDatabasesPath()` на десктопе резолвится относительно CWD. Исправлено фиксированным путём `%APPDATA%\Frogster` |
| Сборка Windows падала | Каскад: Developer Mode → ATL → CMake → сломанная MSVC 14.52 без `cl.exe`. `flutter doctor -v` показывает не всё |

### Ошибки в моих же правках

- XML-комментарии не допускают `--` внутри → Gradle падает на
  `network_security_config.xml`
- `<domain>` в network security config **не поддерживает CIDR**, только точные
  литералы (проверено по документации Android, первая версия с `192.168.0.0`
  не работала бы)
- Тест на `MarkDelivered` дёргал стор напрямую и мутацию **не поймал** —
  понадобился интеграционный тест с реальным хабом и БД
  (`server/internal/delivery/send_test.go`)

## Рабочие договорённости с пользователем

- **Не лезть в систему без спроса.** Просили «просто скажи, где включить»
  вместо самостоятельного инспектирования настроек. Если просят собрать —
  собирать, а не проверять окружение
- **Мутационное тестирование обязательно** для крипты и доставки. Функциональные
  тесты там не доказывают ничего: ошибка в рэтчете не ломает доставку, она
  тихо ломает forward secrecy. Порядок: сломать код → убедиться что тест
  падает → вернуть
- Общение по-русски; код и комментарии — по-английски
- Пользователь тестирует руками на реальном телефоне и присылает логи/скриншоты.
  Его наблюдения точны — «в одну сторону работает, в другую нет» дважды
  указывало прямо на причину

## Где что искать

| Что | Где |
|---|---|
| Криптоядро | `client/lib/crypto/crypto_engine.dart` |
| Резолв устройств, кеш | `client/lib/data/repositories/device_resolver.dart` |
| Приём/отправка сообщений | `client/lib/data/repositories/message_repository.dart` |
| Маршрутизация, офлайн-очередь | `server/internal/delivery/router.go` |
| Выдача ключей | `server/internal/httpapi/keys.go`, `server/internal/store/keys.go` |
| Тесты крипты | `client/test/crypto/`, особенно `crypto_engine_test.dart` |

## Что проверять после изменений

```bash
cd server && go build ./... && go vet ./... && go test ./...
cd ../client && flutter analyze && flutter test
```

Тесты сервера требуют работающего postgres — иначе они пропускаются через
`t.Skipf`, и это легко не заметить.
