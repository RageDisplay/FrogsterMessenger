Ready for review
Select text to add comments on the plan
Frogster — E2EE мессенджер (Go + Flutter)
Context
d:\VectrixSecurity\Frogster пуст — greenfield. Цель: защищённый мессенджер уровня Telegram со сквозным шифрованием, где сервер физически не способен прочитать переписку. Бэкенд — микросервис на Go (горутины/каналы), клиент — единое Flutter-приложение под Windows/macOS/Linux/Android/iOS.

Ключевое архитектурное следствие требования «No Plaintext on Server»: сервер — тупой роутер шифротекста. Он хранит и раздаёт публичные ключи, ставит сообщения в очередь для офлайн-получателей и разносит их по WebSocket, но не имеет ни одного кодового пути, способного расшифровать тело сообщения.

Этот заход покрывает Этапы 0-3 (структура, модели/миграции, аутентификация, WebSocket Hub) с проверкой в конце. Этапы 4-7 — следующим заходом.

Проверенное окружение
Всё проверено на машине, не предполагается. flutter doctor — No issues found.

Компонент	Версия
Go	1.26.0 windows/amd64
Flutter / Dart	3.44.0 stable / 3.12.0
Docker	29.6.1
Android SDK	36.1.0
VS Build Tools	2026 18.4.3
Go (проверено go list -m -versions): gorilla/websocket v1.5.3, gorm.io/gorm v1.31.2, gorm.io/driver/postgres v1.6.0, golang-jwt/jwt/v5 v5.3.1, redis/go-redis/v9 v9.21.0, golang.org/x/crypto v0.54.0, go-chi/chi/v5 v5.3.1, ulule/limiter/v3 v3.11.2, google/uuid v1.6.0, google.golang.org/grpc v1.82.1.

gRPC: go list отдаёт v1.84.0-dev как последнюю — это пре-релиз. Пиним стабильную v1.82.1.

Dart (проверено через pub.dev API): flutter_secure_storage 10.3.1, web_socket_channel 3.0.3, flutter_bloc/flutter_riverpod 3.4.2, sqflite 2.4.3, sqflite_common_ffi 2.4.2, go_router 17.3.0, pointycastle 4.0.0 (MIT), cryptography 2.9.0 (Apache-2.0), x25519 0.1.1 (Apache-2.0), ed25519_edwards (Apache-2.0), grpc 5.1.0, protobuf 6.0.0.

Решение по криптоядру (пересмотрено — важно)
Требование пользователя: мультиплатформа + бесплатно + возможность выката в App Store. Это исключает готовые библиотеки Signal Protocol. Проверено по исходникам, а не по бейджам pub.dev:

Пакет	Лицензия	Источник проверки	Вывод
libsignal_protocol_dart 0.8.2	GPL-3.0	LICENSE в репозитории MixinNetwork	❌ App Store
libsignal 6.1.1	AGPL-3.0	поле license в pubspec	❌ App Store + Rust-артефакты
vodozemac 0.5.0	AGPL-3.0	pub.dev	❌
flutter_olm 2.0.0	AGPL-3.0	pub.dev	❌
signalapp/libsignal (upstream Rust)	AGPL-3.0	LICENSE + README	❌ порт тоже копилефт
Осторожно: страница pub.dev для libsignal показывает бейдж «MIT», но поле license в самом pubspec — AGPL-3.0. Доверять нужно pubspec/LICENSE.

Зрелой permissive-реализации Signal Protocol для Dart не существует. GPL/AGPL несовместимы с ToS App Store (пункт о запрете дополнительных ограничений) — это документированная причина реальных снятий приложений.

Выбранный путь: собственный Double Ratchet на permissive-примитивах
Реализуем X3DH + Double Ratchet поверх cryptography (Apache-2.0) и pointycastle (MIT). Мандат задания («pointycastle или dart:ffi») соблюдается буквально. Мы не изобретаем примитивы — X25519, HKDF-SHA256, AES-256-GCM, HMAC-SHA256 берутся готовыми и проверенными; пишем только протокольный слой (композицию), строго по опубликованным спецификациям Signal.

Почему не dart:ffi к Go: потребовал бы .dll/.so/.a под Windows, Linux, три Android ABI и iOS + обвязку CMake/Gradle/Podspec. Прямой конфликт с требованием «собирается без ошибок» и с мультиплатформенностью.

Это самая рискованная часть проекта, поэтому она изолирована за интерфейсом CryptoEngine и обязательно покрывается тестовыми векторами (см. Этап 5). Ratchet-код не пишется в Этапах 0-3 — у нас есть время подготовить его как следует.

Identity-ключ: Curve25519 + XEdDSA (подтверждено пользователем)
В задании указан crypto/ed25519, но X3DH требует Diffie-Hellman на identity-ключе, а Ed25519 — подписной ключ в форме Эдвардса и DH не выполняет. Подтверждение: libsignal_protocol_dart тянет x25519 и ed25519_edwards как разные зависимости — это разные формы кривой.

Решение (как в Signal):

Клиент: одна пара Curve25519 и для DH, и для подписей через XEdDSA.
Сервер: crypto/ed25519 остаётся и используется по назначению — подпись JWT (алгоритм EdDSA) и аттестации устройств. Мандат соблюдён там, где он корректен (вне E2EE-контура).
crypto/rsa — только для подписи манифестов файловых блобов и опционального RSA-OAEP fallback. Не на горячем пути сообщений (нет forward secrecy).
Зафиксировать в docs/adr/0002-identity-key-curve25519.md.

Прочие решения (подтверждены пользователем)
Групповые чаты — sender-keys (схема Signal/WhatsApp), не MLS. Зрелых Dart-реализаций TreeKEM нет; MLS — отдельный крупный проект.
Инфраструктура — docker compose: postgres:17 + redis:7 + сервер.
Объём — Этапы 0-3, затем проверка и продолжение.
Структура монорепозитория
Frogster/
├── go.work                       # ./server ./tools
├── Makefile                      # dev / test / proto / migrate
├── server/
│   ├── go.mod                    # module github.com/vectrixsecurity/frogster/server
│   ├── cmd/
│   │   ├── frogsterd/main.go     # API + WS
│   │   ├── filed/main.go         # gRPC файлы (Этап 8)
│   │   └── migrate/main.go
│   └── internal/
│       ├── config/               # env-driven Config
│       ├── logging/              # slog + redact_test.go
│       ├── models/               # user, device, keys, chat, message, senderkey, session
│       ├── store/                # postgres.go, users, keys, chats, messages, migrations/*.sql
│       ├── auth/                 # jwt.go, password.go, middleware.go
│       ├── ratelimit/            # redis_bucket.go (Lua), memory_bucket.go, middleware.go
│       ├── httpapi/              # router, register, login, keys, chats, sessions
│       ├── ws/                   # hub.go, client.go, envelope.go, handler.go, presence.go
│       ├── pubsub/               # redis.go, nop.go
│       ├── delivery/             # router.go, offline.go
│       ├── group/                # fanout.go
│       └── gen/frogsterv1/       # protoc output
├── proto/frogster/v1/            # file.proto, envelope.proto
├── client/lib/
│   ├── crypto/                   # crypto_engine.dart (интерфейс), ratchet/, stores/
│   ├── data/{local,remote,repositories}/
│   ├── features/{auth,chat_list,chat,settings,devices}/
│   └── ui/{theme,adaptive,widgets}/
├── deploy/                       # docker-compose.yml, Dockerfile.server
└── docs/                         # architecture, crypto-protocol, threat-model, adr/
Этап 0 — Каркас
go.work, дерево каталогов, flutter create с платформами windows/linux/android/ios/macos, deploy/docker-compose.yml (postgres:17, redis:7, healthchecks).

Проверка: docker compose -f deploy/docker-compose.yml up -d && docker compose ps → healthy; cd client && flutter build windows → успех на пустом приложении.

Этап 1 — Модели и миграции
GORM-структуры + сырые SQL-миграции как источник истины (AutoMigrate только для dev — он молча игнорирует деструктивные изменения и создаёт дрейф схемы).

Ключевые модели:

User — Username (citext, unique), PasswordHash (bcrypt cost 12), TokenVersion (инкремент при смене пароля → массовый отзыв токенов).
Device — RegistrationID, IdentityKeyPub ([]byte, 33 байта Curve25519), RevokedAt. UNIQUE(user_id, registration_id).
SignedPreKey — KeyID, PublicKey, Signature (XEdDSA), Active.
OneTimePreKey — KeyID, PublicKey, ConsumedAt (nullable).
Chat — Type (direct|group), Title ([]byte, зашифрован для групп), Epoch (uint64, инкремент при смене состава).
ChatMember — составной PK (ChatID, UserID), Role, LeftAt.
Message — Seq (серверный), Ciphertext ([]byte, никогда не парсится), CipherType, ExpiresAt.
MessageDelivery — офлайн-очередь: State (pending|delivered|read), per-device Ciphertext.
GroupSenderKeyDistribution — SKDM, зашифрованный попарно (сервер видит только байты).
ActiveSession — refresh-токены для экрана «активные сессии»; хранится RefreshHash (sha256) и IPHash, не сырой IP.
Критично — атомарная выдача one-time prekey. Два параллельных GET /keys не должны получить один и тот же ключ:

UPDATE one_time_pre_keys SET consumed_at = now()
WHERE id = (
  SELECT id FROM one_time_pre_keys
  WHERE device_id = $1 AND consumed_at IS NULL
  ORDER BY key_id LIMIT 1
  FOR UPDATE SKIP LOCKED
)
RETURNING key_id, public_key;
Ноль строк — legal: X3DH деградирует без one-time prekey (слабее FS только для первого сообщения). Клиент пополняет пул при остатке < 20.

Проверка: go run ./cmd/migrate up; docker compose exec postgres psql -U frogster -c '\dt'; go test ./internal/store/... -run TestPreKeyPop — параллельный тест (t.Parallel()), доказывающий отсутствие двойной выдачи.

Этап 2 — Аутентификация и ключи
auth/password.go — bcrypt cost 12.
auth/jwt.go — access 15 мин, refresh 30 дней (opaque, хранится хэш). Claims: UserID, DeviceID, TokenVer.
auth/middleware.go — RequireAuth, проверка Redis-денилиста revoked:jti:*.
Эндпоинты: POST /v1/register (клиент присылает identity key + signed prekey
100 one-time prekeys; сервер только сохраняет, не доказывает владение приватным ключом — как и требовалось), POST /v1/login, GET /v1/keys/{username} (опционально ?device=).
Рекомендуется проверять XEdDSA-самоподпись signed prekey — это дешёвая проверка целостности от кривых загрузок, не доказательство владения.

Rate limiting — Redis token bucket на Lua (атомарный, общий для инстансов), in-memory только как dev-fallback.

Эндпоинт	Ключ	Лимит
POST /v1/register	IP	5 / час
POST /v1/login	IP + username	10 / 15 мин
GET /v1/keys/{u}	UserID	60 / мин (защита от дренажа пула)
WS-кадры	UserID	30 / сек, burst 100
Порядок middleware: Recoverer → RequestID → Logger(redacting) → CORS → RateLimit(IP) → RequireAuth → RateLimit(User) → Handler. IP-лимит до auth (дешёвый отсев), user-лимит после (нужна личность).

Проверка:

curl -sX POST localhost:8080/v1/register -d @testdata/alice.json
TOK=$(curl -sX POST localhost:8080/v1/login -d '{"username":"alice","password":"..."}' | jq -r .access_token)
curl -s localhost:8080/v1/keys/alice -H "Authorization: Bearer $TOK" | jq
for i in $(seq 1 12); do curl -so/dev/null -w"%{http_code} " -X POST localhost:8080/v1/login -d '{}'; done  # ждём 429
go test ./internal/auth/... ./internal/httpapi/...
Этап 3 — WebSocket Hub
Маршрутизация по (UserID, DeviceID) — мультидевайс означает N сокетов на пользователя, и сообщение для устройства 2 не должно попасть в ratchet устройства 1.

type ClientKey struct{ UserID, DeviceID uuid.UUID }

type Hub struct {
    clients    map[ClientKey]*Client
    byUser     map[uuid.UUID]map[uuid.UUID]*Client
    register   chan *Client
    unregister chan *Client
    route      chan *Envelope   // локальные
    inbound    chan *Envelope   // пришли через Redis от другого инстанса
}
func (h *Hub) Run(ctx context.Context)   // единственная горутина-владелец карт
Run — единственный писатель в карты; вся мутация внутри его select.

Пампы (client.go), стандартный контракт gorilla — ровно одна читающая и одна пишущая горутина, писать только из writePump:

const (
    writeWait      = 10 * time.Second
    pongWait       = 60 * time.Second
    pingPeriod     = (pongWait * 9) / 10
    maxMessageSize = 64 << 10   // блобы идут по gRPC
)
send chan []byte буферизован (cap 256); переполнение → закрываем клиента (backpressure = дисконнект, а не безграничная память).

Доставка (delivery/router.go):

Раскрываем получателя во все активные Device.
Локальный (hub.IsLocal) → в client.send.
Иначе есть presence-ключ → broker.Publish в канал frogster:user:<uuid>; владеющая нода забирает из Messages().
Иначе офлайн → MessageDelivery{State: "pending"}.
Presence: SETEX presence:<uid>:<did> 90 <nodeID>, обновляется ping-тикером writePump. TTL самозалечивается после падения ноды.

При подключении FlushOffline отдаёт pending-строки в порядке seq и только потом включается живой трафик (гарантия порядка).

Формат конверта (JSON; payload всё равно base64-непрозрачен):

{ "v":1, "type":"msg", "id":"<ULID>", "chat_id":"uuid",
  "sender":{"user_id":"…","device_id":"…"},
  "ct_type":2, "ciphertext":"<base64>", "ts":1753800000000, "seq":4211 }
Реакции и вложения кладутся внутрь зашифрованного payload — сервер не должен узнавать, кто чем отреагировал.

No plaintext on server — структурная защита, не дисциплина: Envelope реализует slog.LogValuer, возвращая только ID и размеры, поэтому даже slog.Info("msg", "env", env) физически не может напечатать шифротекст. Логи вида c.log.Info("message received", "user_id", …, "bytes", len(raw)).

Проверка: go test ./internal/ws/... (register/unregister/route с фейковыми соединениями); ручной тест двумя websocat; мультиинстансный тест — 2 реплики, A на node1, B на node2, доставка проходит через Redis; убить B, послать 5 сообщений, переподключить → все 5 приходят по порядку.

Верификация Этапов 0-3 (приёмка захода)
docker compose -f deploy/docker-compose.yml up -d      # postgres + redis + сервер
go run ./server/cmd/migrate up
go test ./server/...                                    # все пакеты зелёные
# регистрация двух пользователей, обмен по ws между ними
# офлайн-сценарий: получатель отключён -> сообщение в БД -> флаш при коннекте
docker compose logs frogsterd | grep -iE 'ciphertext|body|plaintext|content'  # должно быть ПУСТО
cd client && flutter build windows                      # каркас собирается
Последняя команда grep выносится в CI как падающий тест.

Основные риски
Собственный Double Ratchet (Этап 5) — главный риск. Ошибка не проявляется как краш: она тихо ломает forward secrecy, тесты остаются зелёными. Митигация: только протокольный слой (примитивы готовые), тестовые векторы, обязательные тесты на out-of-order (1,2,3 → доставка 3,1,2), на уничтожение message key после расшифровки и на переживание рестарта. Ограничить MKSKIPPED (MAX_SKIP=1000) — иначе DoS через исчерпание памяти.
Ротация sender-key при удалении участника — самый опасный логический баг: без ротации удалённый участник продолжает читать группу вечно. Инвариант + отдельный тест.
TOFU обязателен. Раз сервер не проверяет владение ключом, вредоносный сервер может подменить ключ. Нужны: пиннинг при первом контакте, блокировка отправки при смене ключа с явным подтверждением пользователя, экран safety number с QR. Без этого заявление об E2EE несостоятельно.
Метаданные. Сервер видит социальный граф, тайминги и размеры. Зафиксировать как принятую утечку в docs/threat-model.md.
sqflite на десктопе требует sqfliteFfiInit() + databaseFactoryFfi под Platform.isWindows || isLinux.
flutter_secure_storage на Linux требует libsecret/keyring; на headless нужен документированный fallback (ключ из парольной фразы через Argon2id).
Дальнейшие этапы (следующий заход)
4 — группы (sender-keys, epoch); 5 — криптоядро Flutter (самый рискованный); 6 — UI Material 3 адаптивный; 7 — мультидевайс; 8 — файлы по gRPC (AES-256-GCM клиентом до загрузки, ключ едет внутри зашифрованного payload); 9 — hardening и нагрузочный тест.