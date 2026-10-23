-- Avatars, "last seen", and groups that hide their past from newcomers.

-- Avatars of users and of cloud groups, sealed with the storage key like
-- cloud messages. One row per owner; avatar_version on the owner tells
-- clients when theirs is stale, and is bound into the sealing, so an older
-- picture cannot be put back in place of a newer one.
CREATE TABLE IF NOT EXISTS avatars (
    owner_id   UUID PRIMARY KEY,
    version    INT NOT NULL,
    data       BYTEA NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS avatar_version INT NOT NULL DEFAULT 0,
    -- When the user's last device went offline; NULL while never seen.
    ADD COLUMN IF NOT EXISTS last_seen_at TIMESTAMPTZ,
    -- Off: others see "recently" instead of a time, and, in return, the
    -- user sees "recently" for everyone else too.
    ADD COLUMN IF NOT EXISTS last_seen_visible BOOLEAN NOT NULL DEFAULT TRUE;

ALTER TABLE chats
    ADD COLUMN IF NOT EXISTS avatar_version INT NOT NULL DEFAULT 0,
    -- A cloud group whose new members start from the moment they join.
    ADD COLUMN IF NOT EXISTS hide_history BOOLEAN NOT NULL DEFAULT FALSE;
