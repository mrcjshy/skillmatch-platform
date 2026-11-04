-- Philippine mobile phone rule for accounts (owner request 2026-11-05: "a phone number validator").
--
-- The app checks the number live on Create account and saves it as +639XXXXXXXXX, but the account
-- row is written by the client, so the database is the last line of defence. Accepted: the
-- normalized +639XXXXXXXXX form, and the local 09XXXXXXXXX form the existing administrator rows
-- use. Anything else is refused (23514), so a bypassed app cannot store an invalid number.

ALTER TABLE public.users
  ADD CONSTRAINT users_phone_ph_mobile CHECK (phone ~ '^(\+639|09)[0-9]{9}$');

COMMENT ON CONSTRAINT users_phone_ph_mobile ON public.users IS
  'Philippine mobile number: +639XXXXXXXXX (app form) or 09XXXXXXXXX (legacy admin rows). Owner request 2026-11-05.';
