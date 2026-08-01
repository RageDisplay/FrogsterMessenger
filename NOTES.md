# Заметки для следующей сессии

Рабочий контекст проекта Frogster: что уже сделано, где закопаны грабли и как
поднять окружение. Не документация — она в [README.md](README.md),
[docs/crypto-protocol.md](docs/crypto-protocol.md) и [TESTING.md](TESTING.md).

## Состояние

Все 8 этапов закрыты. Клиент — 185 тестов, сервер — все пакеты зелёные под
`-race`. Проект собирается под Windows и Android.

**Не сделано:**
- Групповые чаты: крипта и сервер готовы и протестированы, но UI создания
  группы нет
- Вложения — только изображения (`file_picker` 11 ломает сборку Android, ждём
  стабильную 12.0.0)
- Внешний аудит криптослоя не проводился

**Git:** репозиторий локально **не инициализирован** — это осознанно. Пользователь
заливал код на https://github.com/RageDisplay/FrogsterMessenger вручную; там
лежит более старая версия. `gh` не установлен, токена в окружении нет. Пуш не
делать без явной просьбы: локальной истории нет, так что он потребовал бы
`--force` и перезаписал бы то, что в репозитории.
Корневой `.gitignore` уже написан (важно: `client/build` — 3.2 ГБ, `bin/` — 59 МБ).

## Как поднять окружение

```bash
# 1. Инфраструктура
docker compose -f deploy/docker-compose.yml up -d   # postgres:5432, redis:16379

# 2. Серверы (PowerShell, из d:\VectrixSecurity\Frogster)
#    Запускаются НЕ в докере, а как процессы из bin/
cd server && go build -o ../bin/frogsterd.exe ./cmd/frogsterd
go build -o ../bin/filed.exe ./cmd/filed
```

Запуск через `Start-Process` с `-RedirectStandardOutput`, переменные:
`FROGSTER_ENV=dev`, `FROGSTER_REDIS_URL=redis://localhost:16379/0`,
`FROGSTER_ADDR=0.0.0.0:18080`, `FROGSTER_FILED_ADDR=0.0.0.0:18081`.
Логи: `bin/frogsterd.log`, `bin/filed.log`.

**Порты 18080/18081/16379, а не 8080/8081/6379**: Windows Hyper-V/WSL
резервирует диапазоны, Docker не может привязаться внутри них даже когда никто
не слушает. Проверка: `netsh interface ipv4 show excludedportrange protocol=tcp`.

### Сборка клиентов

IP компьютера в локальной сети: **192.168.50.238**. Телефон (Android,
`adb` id `a2f3c155`) в той же сети.

```bash
cd client
flutter build apk --release --dart-define=FROGSTER_SERVER=http://192.168.50.238:18080 --dart-define=FROGSTER_FILE_HOST=192.168.50.238 --dart-define=FROGSTER_FILE_PORT=18081
flutter build windows --release --dart-define=...то же самое...
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

**При смене IP компьютера** править в ДВУХ местах: `--dart-define` и
`client/android/app/src/main/res/xml/network_security_config.xml` (там адрес
прописан literal — CIDR Android не поддерживает).

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
