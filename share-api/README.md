# Password Entry Share API

The production deployment is a Cloudflare Worker backed by D1. It keeps the existing API and link contract:

- `POST /v1/shares`
- `GET /v1/shares/{shareId}`
- `DELETE /v1/shares/{shareId}`
- `https://share.example.com/s/{shareId}#view-secret`

The Worker stores only the client-encrypted AES-GCM payload. The view secret remains in the URL fragment and is never sent to the Worker.

当前桌面端默认使用 `https://share.password-entry-share.workers.dev`；其他部署者应在桌面端“设置 → 分享服务”中配置自己的 Cloudflare Worker URL，本地开发时可使用 `http://127.0.0.1:8787`。

## Deploy it yourself

You need:

- A Cloudflare account with Workers and D1 enabled.
- Node.js 18 or newer and npm.
- A domain managed by Cloudflare if you want a custom hostname. A `workers.dev` hostname is enough for testing.

The deployment contains one Worker, one D1 database, and one static asset. The Worker handles the API and serves `public/share.html`; D1 stores only the encrypted payload and share lifecycle fields. The URL fragment after `#` contains the view secret and is never sent to Cloudflare.

### Automated deployment

From this directory, run:

```bash
npm install
npx wrangler login
npm run deploy:self
```

`deploy:self` performs these steps:

1. Checks that Wrangler is authenticated.
2. Looks for a D1 database named `password-entry-share` in the logged-in Cloudflare account.
3. Creates it in the Asia-Pacific region if it does not exist.
4. Writes that account's database ID and database name into the local `wrangler.jsonc`.
5. Applies the share and rate-limit migrations to the remote database.
6. Runs the TypeScript check and deploys the Worker.

To choose a different database name or primary location:

```bash
DB_NAME=my-password-entry-share D1_LOCATION=weur npm run deploy:self
```

The accepted `D1_LOCATION` values are `weur`, `eeur`, `apac`, `oc`, `wnam`, and `enam`. The deployment command prints the resulting Worker URL. Put that URL into the desktop app under “Settings → Share Service”.

### Manual deployment

If you prefer to review every step:

```bash
npm install
npx wrangler login
npx wrangler d1 create password-entry-share --location apac
```

Copy the returned `database_id` into `wrangler.jsonc`, replacing `REPLACE_WITH_D1_DATABASE_ID`, then run:

```bash
npm run db:migrate:remote
npm run typecheck
npm run deploy
```

For local development, use a local D1 instance and Wrangler's local server:

```bash
npm run db:migrate:local
npm run dev
```

The fallback Python server can also be used when Cloudflare tooling is unavailable:

```bash
python3 server.py
```

### Custom domain

After deployment, open the Worker in the Cloudflare dashboard and add a Worker Custom Domain, such as `share.example.com`. Then set that full HTTPS origin in the desktop app. The API and share page must use the same origin because the recipient page calls `/v1/shares/{shareId}` relative to its own URL.

### Updating an existing deployment

After changing `src/worker.ts`, `public/share.html`, or the migration files:

```bash
npm run typecheck
npm run db:migrate:remote   # only when there is a new migration
npm run deploy
```

Use `npm run deploy:self` for first-time provisioning. Use `npm run deploy` for later code-only updates.

## Local Python fallback

`server.py` remains available for offline local testing, but it is not the production deployment. The Cloudflare implementation is in `src/worker.ts`; the recipient page is deployed from `public/share.html`.

The service intentionally does not include accounts, email verification, attachments, or one-time links yet. Share creation is limited to 10 requests per client per minute, other API calls to 60 requests per client per minute, and a scheduled cleanup removes old expired or revoked rows.
