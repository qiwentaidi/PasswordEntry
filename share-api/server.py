#!/usr/bin/env python3
"""Minimal Password Entry share API.

The service stores only client-encrypted item payloads. The view secret stays
in the URL fragment and is never sent in an HTTP request.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import sqlite3
from datetime import datetime, timedelta, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parent
DB_PATH = Path(os.environ.get("PASSWORD_ENTRY_SHARE_DB", ROOT / "shares.sqlite3"))
HOST = os.environ.get("PASSWORD_ENTRY_SHARE_HOST", "127.0.0.1")
PORT = int(os.environ.get("PASSWORD_ENTRY_SHARE_PORT", "8787"))
MAX_CIPHERTEXT_BYTES = 256 * 1024
MAX_CIPHERTEXT_B64 = MAX_CIPHERTEXT_BYTES * 4 // 3 + 4
MAX_LIFETIME_SECONDS = 30 * 24 * 60 * 60
SHARE_ID_RE = re.compile(r"^[A-Za-z0-9_-]{20,64}$")
BASE64URL_RE = re.compile(r"^[A-Za-z0-9_-]+$")


def utc_now() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def parse_time(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp must include a timezone")
    return parsed.astimezone(timezone.utc).replace(microsecond=0)


def iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def valid_b64url(value: object, max_length: int = MAX_CIPHERTEXT_B64) -> bool:
    if not isinstance(value, str) or not value or len(value) > max_length or not BASE64URL_RE.fullmatch(value):
        return False
    try:
        base64.urlsafe_b64decode(value + "=" * ((4 - len(value) % 4) % 4))
    except ValueError:
        return False
    return True


def connect() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(DB_PATH)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA busy_timeout=5000")
    connection.executescript((ROOT / "schema.sql").read_text())
    return connection


class ShareHandler(BaseHTTPRequestHandler):
    server_version = "PasswordEntryShare/1.0"

    def log_message(self, format: str, *args: object) -> None:
        # Do not log query strings or request bodies: secrets must not end up in logs.
        super().log_message(format, *args)

    def send_json(self, status: int, body: dict[str, object] | None = None) -> None:
        payload = b"" if body is None else json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if payload:
            self.wfile.write(payload)

    def send_share_page(self) -> None:
        payload = (ROOT / "share.html").read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def read_json(self) -> dict[str, object] | None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > MAX_CIPHERTEXT_B64 + 4096:
                return None
            value = json.loads(self.rfile.read(length))
            return value if isinstance(value, dict) else None
        except (ValueError, json.JSONDecodeError):
            return None

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Revoke-Token")
        self.send_header("Access-Control-Max-Age", "600")
        self.end_headers()

    def do_POST(self) -> None:
        if urlparse(self.path).path != "/v1/shares":
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        body = self.read_json()
        if body is None:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid JSON"})
            return
        try:
            share_id = body["shareId"]
            schema_version = body["schemaVersion"]
            algorithm = body["algorithm"]
            iv = body["iv"]
            ciphertext = body["ciphertext"]
            expires_at = parse_time(body["expiresAt"])
            revoke_hash = body["revokeTokenHash"]
            now = utc_now()
            if not isinstance(share_id, str) or not SHARE_ID_RE.fullmatch(share_id):
                raise ValueError("invalid share id")
            if schema_version != 1 or algorithm != "A256GCM":
                raise ValueError("unsupported share format")
            if not valid_b64url(iv, 128) or len(base64.urlsafe_b64decode(iv + "=" * ((4 - len(iv) % 4) % 4))) != 12:
                raise ValueError("invalid iv")
            if not valid_b64url(ciphertext):
                raise ValueError("invalid ciphertext")
            if not isinstance(revoke_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", revoke_hash):
                raise ValueError("invalid revoke token hash")
            if expires_at <= now or expires_at > now + timedelta(seconds=MAX_LIFETIME_SECONDS):
                raise ValueError("expiration must be within 30 days")
        except (KeyError, TypeError, ValueError, OverflowError):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid share payload"})
            return

        connection = connect()
        try:
            connection.execute(
                "INSERT INTO shares (id, schema_version, algorithm, iv, ciphertext, revoke_token_hash, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (share_id, schema_version, algorithm, iv, ciphertext, revoke_hash, iso(now), iso(expires_at)),
            )
            connection.commit()
        except sqlite3.IntegrityError:
            connection.rollback()
            self.send_json(HTTPStatus.CONFLICT, {"error": "share id already exists"})
            return
        finally:
            connection.close()
        self.send_json(HTTPStatus.CREATED, {"shareId": share_id, "expiresAt": iso(expires_at)})

    def do_GET(self) -> None:
        if re.fullmatch(r"/s/[A-Za-z0-9_-]{20,64}", urlparse(self.path).path):
            self.send_share_page()
            return
        match = re.fullmatch(r"/v1/shares/([A-Za-z0-9_-]+)", urlparse(self.path).path)
        if not match:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        share_id = match.group(1)
        connection = connect()
        try:
            row = connection.execute("SELECT * FROM shares WHERE id = ?", (share_id,)).fetchone()
            if row is None:
                self.send_json(HTTPStatus.NOT_FOUND, {"error": "share not found"})
                return
            now = utc_now()
            if row["revoked_at"] is not None or parse_time(row["expires_at"]) <= now:
                self.send_json(HTTPStatus.GONE, {"error": "share expired or revoked"})
                return
            if row["max_views"] is not None and row["view_count"] >= row["max_views"]:
                self.send_json(HTTPStatus.GONE, {"error": "share view limit reached"})
                return
            connection.execute("UPDATE shares SET view_count = view_count + 1, last_viewed_at = ? WHERE id = ?", (iso(now), share_id))
            connection.commit()
            self.send_json(HTTPStatus.OK, {
                "schemaVersion": row["schema_version"],
                "algorithm": row["algorithm"],
                "iv": row["iv"],
                "ciphertext": row["ciphertext"],
                "expiresAt": row["expires_at"],
            })
        finally:
            connection.close()

    def do_DELETE(self) -> None:
        match = re.fullmatch(r"/v1/shares/([A-Za-z0-9_-]+)", urlparse(self.path).path)
        if not match:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        revoke_token = self.headers.get("X-Revoke-Token", "")
        token_hash = hashlib.sha256(revoke_token.encode()).hexdigest()
        share_id = match.group(1)
        connection = connect()
        try:
            cursor = connection.execute(
                "UPDATE shares SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL AND revoke_token_hash = ?",
                (iso(utc_now()), share_id, token_hash),
            )
            connection.commit()
            if cursor.rowcount != 1:
                self.send_json(HTTPStatus.NOT_FOUND, {"error": "share not found or token invalid"})
                return
        finally:
            connection.close()
        self.send_json(HTTPStatus.NO_CONTENT)


def main() -> None:
    connect().close()
    server = ThreadingHTTPServer((HOST, PORT), ShareHandler)
    print(f"Password Entry Share API listening on http://{HOST}:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
