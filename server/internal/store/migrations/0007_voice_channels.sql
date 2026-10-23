-- Voice channels of cloud groups. Only the channels themselves are kept:
-- who is talking in them right now lives in the server's memory.
CREATE TABLE IF NOT EXISTS voice_channels (
    id         UUID PRIMARY KEY,
    chat_id    UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    -- Sealed with the storage key, like a cloud group's title.
    name       BYTEA NOT NULL,
    position   INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS voice_channels_chat ON voice_channels (chat_id, position);
