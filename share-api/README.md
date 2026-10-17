# Password Entry Share API

This is the minimal share service for local development and a small deployment. It stores only AES-GCM ciphertext, never the view secret from the URL fragment.

```bash
python3 share-api/server.py
```

Environment variables:

- `PASSWORD_ENTRY_SHARE_HOST` (default `127.0.0.1`)
- `PASSWORD_ENTRY_SHARE_PORT` (default `8787`)
- `PASSWORD_ENTRY_SHARE_DB` (default `share-api/shares.sqlite3`)

The desktop client uses `PASSWORD_ENTRY_SHARE_API_URL` to choose the API base URL. The current default is `http://127.0.0.1:8787`; set it to the HTTPS share service before distributing the app.

The service is intentionally missing accounts, email verification, attachments, and one-time links. Add authentication, HTTPS, rate limiting, and encrypted backups before exposing it publicly.

The same process serves the recipient page at `/s/{shareId}`. In production, put it behind HTTPS and a reverse proxy or deploy the API and static page to equivalent managed services.
