-- Client-generated message ids and refresh-token rotation.

-- The id the sending client gave a message. It is what every recipient sees,
-- whether the message reaches them live or from the offline queue, so a
-- reply, reaction or acknowledgement refers to the same message everywhere.
-- Nullable: rows from before this column existed keep using their UUID.
ALTER TABLE messages
    ADD COLUMN IF NOT EXISTS client_id VARCHAR(64);

-- Makes a resend idempotent. A client that lost the acknowledgement of a
-- message sends it again with the same id; the duplicate must resolve to the
-- stored message instead of being delivered twice, because a ratchet message
-- decrypts only once.
CREATE UNIQUE INDEX IF NOT EXISTS messages_sender_client_id_uniq
    ON messages(chat_id, sender_dev_id, client_id)
    WHERE client_id IS NOT NULL;

-- Refresh tokens rotate on every use. The previous hash is kept briefly so a
-- client that lost the response to a refresh can retry, and so that presenting
-- an older token -- the signature of a stolen one being replayed -- can be
-- told apart from an unknown token.
ALTER TABLE active_sessions
    ADD COLUMN IF NOT EXISTS prev_refresh_hash VARCHAR(64),
    ADD COLUMN IF NOT EXISTS rotated_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_active_sessions_prev_refresh_hash
    ON active_sessions(prev_refresh_hash)
    WHERE prev_refresh_hash IS NOT NULL;

-- Signed prekeys are now rotated, so lookups of the active one are frequent.
CREATE INDEX IF NOT EXISTS idx_signed_pre_keys_active
    ON signed_pre_keys(device_id)
    WHERE active;
