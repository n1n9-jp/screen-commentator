# Supabase setup

Full startup and verification steps are documented in [Remote Posting Startup Guide](../docs/guides/remote-posting-startup.md).

Apply the migrations in `supabase/migrations/` in filename order, then register a host admin token hash before using the macOS app to create rooms. If posting fails with `column reference "created_at" is ambiguous`, run `202606220003_disambiguate_submit_comment.sql` in the Supabase SQL Editor.

```sql
insert into public.host_admin_tokens(token_hash, label)
values (
  encode(extensions.digest('replace-with-a-long-random-token', 'sha256'), 'hex'),
  'default admin token'
);
```

Use the original token string, not the hash, in the macOS app's `Remote Posting > Host admin token` field.

Auth setup:

- Enable Email OTP in Supabase Auth.
- Use an OTP email template that includes `{{ .Token }}`.
- The RPC layer accepts only email domains equal to `musabi.ac.jp` or ending with `.musabi.ac.jp`.
- Enable the Before User Created Auth Hook and point it to `pg-functions://postgres/public/hook_restrict_musabi_signup` so new signups are rejected server-side unless the email domain is `musabi.ac.jp` or a subdomain.

Web app environment variables:

```bash
VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-key
```

Do not commit real admin tokens, host tokens, or test email addresses.
