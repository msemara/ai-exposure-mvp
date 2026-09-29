-- Initial server schema from docs/spec.md, "Server schema (Postgres)".
-- The server stores only ciphertext and wrapped keys; it never parses blobs.
-- auth.users is managed by Supabase Auth; our tables reference it.

CREATE TABLE public.profiles (
  id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.wrapped_keys (
  user_id       UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  method        TEXT NOT NULL,              -- passkey_prf | recovery | passphrase
  credential_id TEXT NOT NULL DEFAULT '',   -- passkey credential for passkey_prf
  key_version   INT NOT NULL,
  wrapped_dk    BYTEA NOT NULL,
  kdf_params    JSONB,                      -- salt, Argon2id params where used
  PRIMARY KEY (user_id, method, key_version, credential_id)
);

CREATE TABLE public.devices (
  id          UUID PRIMARY KEY,
  user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  revoked_at  TIMESTAMPTZ,
  UNIQUE (id, user_id)
);

CREATE TABLE public.rollup_blobs (
  user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id   UUID NOT NULL,
  period      TEXT NOT NULL DEFAULT 'day' CHECK (period IN ('day', 'month')),
  day         DATE NOT NULL,                -- first of month when period = 'month'
  key_version INT NOT NULL,
  nonce       BYTEA NOT NULL CHECK (octet_length(nonce) = 24),
  ciphertext  BYTEA NOT NULL CHECK (octet_length(ciphertext) IN (4096, 16384, 65536)),
  version     INT NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, device_id, period, day),
  FOREIGN KEY (device_id, user_id) REFERENCES public.devices(id, user_id) ON DELETE CASCADE
);

-- Reject stale or replayed writes.
CREATE FUNCTION public.check_blob_version() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.version <= OLD.version THEN
    RAISE EXCEPTION 'stale version';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
CREATE TRIGGER blob_version BEFORE UPDATE ON public.rollup_blobs
  FOR EACH ROW EXECUTE FUNCTION public.check_blob_version();

-- Cap active devices per user.
CREATE FUNCTION public.check_device_cap() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF (SELECT count(*) FROM public.devices
      WHERE user_id = NEW.user_id AND revoked_at IS NULL) >= 10 THEN
    RAISE EXCEPTION 'device limit reached';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER device_cap BEFORE INSERT ON public.devices
  FOR EACH ROW EXECUTE FUNCTION public.check_device_cap();

ALTER TABLE public.profiles     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wrapped_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.devices      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rollup_blobs ENABLE ROW LEVEL SECURITY;

-- (select auth.uid()) is evaluated once per statement rather than per row.
CREATE POLICY own_profile ON public.profiles     FOR SELECT USING (id = (select auth.uid()));
CREATE POLICY own_keys    ON public.wrapped_keys FOR ALL    USING (user_id = (select auth.uid()))
  WITH CHECK (user_id = (select auth.uid()));
CREATE POLICY own_devices ON public.devices      FOR ALL    USING (user_id = (select auth.uid()))
  WITH CHECK (user_id = (select auth.uid()));
CREATE POLICY own_blobs   ON public.rollup_blobs FOR ALL    USING (user_id = (select auth.uid()))
  WITH CHECK (user_id = (select auth.uid()) AND EXISTS (
    SELECT 1 FROM public.devices d
    WHERE d.id = device_id AND d.user_id = (select auth.uid()) AND d.revoked_at IS NULL));
