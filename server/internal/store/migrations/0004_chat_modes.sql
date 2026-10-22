-- Cloud and secret chats, editable history, read positions, profiles.

-- A chat is either "secret" (end-to-end encrypted; the server relays opaque
-- ciphertext and keeps no readable history) or "cloud" (protected in transit
-- by TLS and at rest by the server's storage key; history is kept and syncs
-- to every device). Chats from before this column existed were all
-- end-to-end encrypted.
ALTER TABLE chats
    ADD COLUMN IF NOT EXISTS mode VARCHAR(8) NOT NULL DEFAULT 'secret';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chats_mode_check') THEN
        ALTER TABLE chats ADD CONSTRAINT chats_mode_check CHECK (mode IN ('cloud', 'secret'));
    END IF;
END $$;

-- Cloud messages are stored as payloads sealed with the storage key
-- (cipher_type 0). The constraint is rebuilt rather than altered because
-- Postgres cannot change a CHECK in place.
ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_cipher_type_check;
ALTER TABLE messages
    ADD CONSTRAINT messages_cipher_type_check CHECK (cipher_type IN (0, 1, 2, 3));

-- What a cloud message does: "" is an ordinary message; "edit", "delete",
-- "react" and "unreact" are events that change an earlier message, named by
-- target_id. Events get a seq of their own, so a device that was offline
-- learns about them the same way it learns about new messages. Always empty
-- for secret chats, whose events live inside the ciphertext.
ALTER TABLE messages
    ADD COLUMN IF NOT EXISTS kind      VARCHAR(8)  NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS target_id VARCHAR(64),
    ADD COLUMN IF NOT EXISTS edited_at  TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- History pages skip events; sync pages include them.
CREATE INDEX IF NOT EXISTS idx_messages_chat_plain
    ON messages(chat_id, seq)
    WHERE kind = '';

-- Reactions on cloud messages, so a device that joins later sees them.
CREATE TABLE IF NOT EXISTS message_reactions (
    message_id UUID        NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    user_id    UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    emoji      VARCHAR(16) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (message_id, user_id, emoji)
);

-- How far each member has read, by seq. Drives unread counts across devices
-- and the "read" ticks other members see.
ALTER TABLE chat_members
    ADD COLUMN IF NOT EXISTS last_read_seq BIGINT NOT NULL DEFAULT 0;

-- Profile text shown to contacts.
ALTER TABLE users
    ADD COLUMN IF NOT EXISTS bio VARCHAR(140) NOT NULL DEFAULT '';

-- Username prefix search.
CREATE INDEX IF NOT EXISTS idx_users_username_prefix
    ON users ((lower(username::text)) text_pattern_ops);
