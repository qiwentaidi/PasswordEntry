---
name: password-entry-share-deploy
description: Deploy or update this repository's Password Entry share service on Cloudflare Workers and D1 after the user explicitly requests deployment.
---

# Password Entry Share Deploy

Use this skill only for an explicit request to deploy or update the Password Entry share service. Work from the repository's `share-api/` directory and preserve the existing API paths and link format.

## First deployment

1. Run `npm install` in `share-api/`.
2. Run `npx wrangler whoami`.
3. If Wrangler is not authenticated, run `npx wrangler login`, tell the user to complete the browser authorization, and wait for the user to confirm before continuing. Never use a temporary preview account for a production deployment.
4. Run `npm run deploy:self`. This provisions or reuses the account's D1 database, applies migrations, type-checks the Worker, and deploys it.
5. Report the Worker URL printed by Wrangler. Ask the user to enter that URL in the desktop app under “设置 → 分享服务”.

Do not print or expose OAuth tokens, API tokens, database credentials, or the contents of `.dev.vars`. Do not commit an account-specific D1 ID from `wrangler.jsonc` unless the user explicitly asks for that account binding to be committed.

## Existing deployment

For a code or static-page update, use `npm run typecheck` and then `npm run deploy` when `wrangler.jsonc` contains the intended account's D1 ID. If it contains `REPLACE_WITH_D1_DATABASE_ID`, use `npm run deploy:self` instead.

After a deployment, report the Worker URL, migration result, type-check result, and deployment version. If the network or Cloudflare authentication blocks progress, stop at that boundary and tell the user what action is required.

## Acceptance checks

Use the following checks when the user asks for deployment acceptance:

- The Worker serves `/s/{shareId}` and `/v1/shares/{shareId}` from the same origin.
- A newly created share can be opened and decrypted in a browser.
- Removing the URL fragment shows `分享链接已失效或者过期。`.
- Revoking or expiring a share produces the same message.
- The desktop app can create, copy, and revoke a share using the configured Worker URL.

The service stores only encrypted payloads in D1. Do not add server-side decryption or log the URL fragment.
