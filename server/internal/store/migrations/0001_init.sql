-- Frogster initial schema.
--
-- Raw SQL is the source of truth for the schema. GORM AutoMigrate is used only
-- as a dev convenience because it silently refuses destructive changes, which
-- produces drift that is discovered late.

CREATE EXTENSION IF NOT EXISTS citext;

-- Accounts ------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS users (
    id            UUID PRIMARY KEY,
    username      CITEXT      NOT NULL UNIQUE,
    display_name  VARCHAR(64) NOT NULL DEFAULT '',
    password_hash VARCHAR(72) NOT NULL,
    token_version INTEGER     NOT NULL DEFAULT 1,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Devices and key material --------------------------------------------------

CREATE TABLE IF NOT EXISTS devices (
    id               UUID PRIMARY KEY,
    user_id          UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    registration_id  BIGINT      NOT NULL,
    device_name      VARCHAR(64) NOT NULL DEFAULT '',
    -- Curve25519 identity public key, DJB type-prefixed (33 bytes).
    identity_key_pub BYTEA       NOT NULL,
    last_seen_at     TIMESTAMPTZ,
    revoked_at       TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT devices_user_registration_uniq UNIQUE (user_id, registration_id),
    CONSTRAINT devices_identity_key_len CHECK (octet_length(identity_key_pub) = 33)
);

CREATE INDEX IF NOT EXISTS idx_devices_user_id    ON devices(user_id);
CREATE INDEX IF NOT EXISTS idx_devices_revoked_at ON devices(revoked_at);

CREATE TABLE IF NOT EXISTS signed_pre_keys (
    id         UUID PRIMARY KEY,
    device_id  UUID        NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    key_id     BIGINT      NOT NULL,
    public_key BYTEA       NOT NULL,
    -- XEdDSA signature over public_key by the device identity key (64 bytes).
    signature  BYTEA       NOT NULL,
    active     BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT signed_pre_keys_device_key_uniq UNIQUE (device_id, key_id),
    CONSTRAINT signed_pre_keys_pub_len CHECK (octet_length(public_key) = 33),
    CONSTRAINT signed_pre_keys_sig_len CHECK (octet_length(signature)  = 64)
);

CREATE INDEX IF NOT EXISTS idx_signed_pre_keys_device_id ON signed_pre_keys(device_id);
CREATE INDEX IF NOT EXISTS idx_signed_pre_keys_active    ON signed_pre_keys(active);

CREATE TABLE IF NOT EXISTS one_time_pre_keys (
    id          BIGSERIAL PRIMARY KEY,
    device_id   UUID   NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    key_id      BIGINT NOT NULL,
    public_key  BYTEA  NOT NULL,
    consumed_at TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT one_time_pre_keys_device_key_uniq UNIQUE (device_id, key_id),
    CONSTRAINT one_time_pre_keys_pub_len CHECK (octet_length(public_key) = 33)
);

-- Partial index: the hot query only ever looks for unconsumed keys.
CREATE INDEX IF NOT EXISTS idx_otp_available
    ON one_time_pre_keys(device_id, key_id)
    WHERE consumed_at IS NULL;

-- Chats ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS chats (
    id         UUID PRIMARY KEY,
    type       VARCHAR(8) NOT NULL,
    -- Client-encrypted for groups; NULL for direct chats.
    title      BYTEA,
    creator_id UUID       REFERENCES users(id) ON DELETE SET NULL,
    epoch      BIGINT     NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chats_type_check CHECK (type IN ('direct', 'group'))
);

CREATE TABLE IF NOT EXISTS chat_members (
    chat_id   UUID       NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    user_id   UUID       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role      VARCHAR(8) NOT NULL DEFAULT 'member',
    joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    left_at   TIMESTAMPTZ,
    PRIMARY KEY (chat_id, user_id),
    CONSTRAINT chat_members_role_check CHECK (role IN ('member', 'admin'))
);

CREATE INDEX IF NOT EXISTS idx_chat_members_user_id ON chat_members(user_id);

-- Messages ------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS messages (
    id             UUID PRIMARY KEY,
    chat_id        UUID   NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    seq            BIGINT NOT NULL,
    sender_id      UUID   NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sender_dev_id  UUID   NOT NULL,
    -- Opaque ciphertext. Never parsed or logged by the server.
    ciphertext     BYTEA  NOT NULL,
    cipher_type    SMALLINT NOT NULL,
    content_hint   VARCHAR(16) NOT NULL DEFAULT 'default',
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at     TIMESTAMPTZ,
    CONSTRAINT messages_chat_seq_uniq UNIQUE (chat_id, seq),
    CONSTRAINT messages_cipher_type_check CHECK (cipher_type IN (1, 2, 3))
);

CREATE INDEX IF NOT EXISTS idx_messages_chat_seq   ON messages(chat_id, seq);
CREATE INDEX IF NOT EXISTS idx_messages_sender_id  ON messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(created_at);
CREATE INDEX IF NOT EXISTS idx_messages_expires_at ON messages(expires_at);

CREATE TABLE IF NOT EXISTS message_deliveries (
    id           BIGSERIAL PRIMARY KEY,
    message_id   UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id    UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    -- Per-device ratchet output for 1:1; NULL for group sender-key messages.
    ciphertext   BYTEA,
    state        VARCHAR(10) NOT NULL DEFAULT 'pending',
    delivered_at TIMESTAMPTZ,
    read_at      TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT message_deliveries_uniq UNIQUE (message_id, device_id),
    CONSTRAINT message_deliveries_state_check
        CHECK (state IN ('pending', 'delivered', 'read'))
);

CREATE INDEX IF NOT EXISTS idx_message_deliveries_message_id ON message_deliveries(message_id);

-- Offline queue drain: fetch this device's pending mail in order.
CREATE INDEX IF NOT EXISTS idx_deliveries_pending
    ON message_deliveries(user_id, device_id, id)
    WHERE state = 'pending';

-- Group sender keys ---------------------------------------------------------

CREATE TABLE IF NOT EXISTS group_sender_key_distributions (
    id             BIGSERIAL PRIMARY KEY,
    chat_id        UUID   NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    epoch          BIGINT NOT NULL,
    sender_user_id UUID   NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sender_dev_id  UUID   NOT NULL,
    recip_user_id  UUID   NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recip_dev_id   UUID   NOT NULL,
    -- SKDM sealed inside the pairwise session. Opaque to the server.
    ciphertext     BYTEA  NOT NULL,
    consumed_at    TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT gskd_uniq UNIQUE (chat_id, epoch, sender_dev_id, recip_dev_id)
);

CREATE INDEX IF NOT EXISTS idx_gskd_chat_id     ON group_sender_key_distributions(chat_id);
CREATE INDEX IF NOT EXISTS idx_gskd_recipient   ON group_sender_key_distributions(recip_user_id, recip_dev_id);

-- Sessions ------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS active_sessions (
    id           UUID PRIMARY KEY,
    user_id      UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id    UUID        NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    -- SHA-256 hex of the opaque refresh token; the token itself is never stored.
    refresh_hash VARCHAR(64) NOT NULL UNIQUE,
    user_agent   VARCHAR(256) NOT NULL DEFAULT '',
    ip_hash      VARCHAR(64)  NOT NULL DEFAULT '',
    expires_at   TIMESTAMPTZ NOT NULL,
    revoked_at   TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_active_sessions_user_id    ON active_sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_active_sessions_device_id  ON active_sessions(device_id);
CREATE INDEX IF NOT EXISTS idx_active_sessions_expires_at ON active_sessions(expires_at);
