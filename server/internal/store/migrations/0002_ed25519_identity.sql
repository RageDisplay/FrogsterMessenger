-- Adds the Ed25519 signing identity key alongside the Curve25519 DH key.
--
-- A device needs both: Curve25519 cannot produce signatures and Ed25519 cannot
-- perform Diffie-Hellman. Signal solves this with one Curve25519 key plus
-- XEdDSA, but that needs Edwards-curve arithmetic that no maintained
-- permissive Dart package exposes -- see docs/adr/0002.
--
-- Nullable so existing rows stay valid; devices registered before this column
-- existed simply cannot have their signed prekeys verified until they
-- re-register.

ALTER TABLE devices
    ADD COLUMN IF NOT EXISTS identity_key_ed25519 BYTEA;

-- Ed25519 public keys are exactly 32 bytes (no DJB type prefix).
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'devices_identity_ed25519_len'
    ) THEN
        ALTER TABLE devices
            ADD CONSTRAINT devices_identity_ed25519_len
            CHECK (identity_key_ed25519 IS NULL
                   OR octet_length(identity_key_ed25519) = 32);
    END IF;
END $$;
