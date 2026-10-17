# Password Entry Share API

The production deployment is a Cloudflare Worker backed by D1. It keeps the existing API and link contract:

- `POST /v1/shares`
- `GET /v1/shares/{shareId}`
- `DELETE /v1/shares/{shareId}`
- `https://share.example.com/s/{shareId}#view-secret`

The Worker stores only the client-encrypted AES-GCM payload. The view secret remains in the URL fragment and is never sent to the Worker.

The current deployment is available at `https://password-entry-share.password-entry-share.workers.dev`. Configure this origin in the desktop app under “Settings → Share Service” for acceptance testing.

## Deploy to Cloudflare

Install dependencies from this directory:

```bash
npm install
```

Create a D1 database and copy its ID into `wrangler.jsonc`:

```bash
npx wrangler d1 create password-entry-share
```

Apply the schema locally while developing:

```bash
npm run db:migrate:local
npm run dev
```

Apply it to the remote D1 database and deploy:

```bash
npm run db:migrate:remote
npm run deploy
```

The current deployment is `https://password-entry-share.password-entry-share.workers.dev`. The desktop app uses this origin by default; you can override it under “Settings → Share Service” when using a custom domain or local server.

## Local Python fallback

`server.py` remains available for offline local testing, but it is not the production deployment. The Cloudflare implementation is in `src/worker.ts`; the recipient page is deployed from `public/share.html`.

The service intentionally does not include accounts, email verification, attachments, or one-time links yet. Add rate limiting and abuse controls before opening anonymous creation to the public internet.
