-- "Clear history" for one member of a cloud chat.
--
-- Cloud history lives on the server, so deleting it on a device alone would
-- bring it back with the next sync. A member who clears a chat moves this
-- mark to the chat's current end; history, sync and the chat list then show
-- them only what came after it. Other members keep their history.
ALTER TABLE chat_members
    ADD COLUMN IF NOT EXISTS cleared_seq BIGINT NOT NULL DEFAULT 0;
