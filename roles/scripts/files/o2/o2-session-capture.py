#!/usr/bin/env python3
"""O2/Movistar interactive session capture for the o2cloud-webdav gateway.

WHY: The gateway's own interactive login (O2LoginCoordinator) wedges on the
Movistar SPA (its `_capture` awaits context.cookies() against a frozen
renderer, which never resolves). This standalone script drives the SAME
Playwright profile directly, without the coordinator, and reliably extracts a
fresh O2Session.

It runs INSIDE the o2cloud-webdav container (playwright + chromium + the
persistent profile live there). It opens the gateway's Playwright profile in a
headed Chromium (visible on noVNC). The SPA may auto-login with the saved
cookies; if those are stale it clears them and reloads so the operator can
complete the Movistar login (phone + verification code).

On success it writes an O2Session JSON (camelCase keys, the exact schema the
gateway's POST /api/admin/o2/import endpoint expects) to the output path.

OAUTH BUNDLE (renewable session) — why this matters
--------------------------------------------------
A Movistar session dies server-side every ~1.5-3 days no matter what. The
gateway can only renew it when the stored session carries an `oauthBundle`
(the OAuth access token):

    O2Session.can_refresh == bool(oauth_bundle.strip())

With can_refresh=False the keepalive can only DETECT the death and alert; a
human must redo the phone+OTP login. With can_refresh=True the gateway
renews on its own: a rejected request returns the rotated bundle in the
`Authorization: oauth <bundle>` response header, and `_oauth_login()` POSTs
`login/oauth?action=login&responsetime=true` to mint a new key+bundle.

The bundle is ONLY exchanged during the interactive login, on
`/login/oauth` (path suffix `/login/oauth`, under the sapi base). That
exchange happens in the RESPONSE (header `authorization: oauth <bundle>` and
JSON body `data.access_token`), so this script MUST listen to responses and
parse their bodies. The previous version only looked at REQUEST headers, so
`oauthBundle` was always "" and every session was unrenewable.

This script mirrors the gateway's own capture logic (o2gateway/o2/login.py):
  * request  headers -> `authorization: oauth <bundle>` -> oauthBundle
  * response headers -> `authorization: oauth <bundle>` -> oauthBundle
  * response JSON    -> data.access_token -> oauthBundle
                      -> data.validationkey -> validationKey (canonical)
                      -> data["encryption-token"] -> encryptionToken

USAGE (inside the container)
---------------------------
   1. Kill any gateway chromium (it holds the profile):
        for p in /proc/[0-9]*; do [ "$(readlink "$p/exe" 2>/dev/null)" = \
          /ms-playwright/chromium-*/chrome-linux*/chrome ] && kill -9 "${p##*/}"; done
      rm -f /config/playwright-o2-profile/movistar/Singleton*
   2. Run detached (it waits up to 600s for the operator to log in):
        nohup python3 o2-session-capture.py <dead_key[,key2,...]> /tmp/capout.json \
          > /tmp/cap_stdout.log 2>&1 &
   3. The operator logs in on noVNC:
        http://<host>:6080/vnc.html?autoconnect=true
      Progress is written to /tmp/cap_heartbeat (starting / stale_clearing /
      waiting_user_login / success / timeout). A BLACK SCREEN at the end is NOT
      a failure: the SPA still issues sapi calls carrying the validationkey.

   MUST run as the gateway user (uid 10001) with the right HOME, or the
   persistent profile is left root-owned and the next login breaks:
        docker exec -d -u o2gateway -e DISPLAY=:99 -e HOME=/config \
          o2cloud-webdav sh -c "python3 /tmp/o2-session-capture.py '<deadkey>' \
          /tmp/capout.json > /tmp/cap_stdout.log 2>&1"

DIAGNOSTIC MODE
---------------
   Set O2_CAPTURE_DIAG=/tmp/cap_oauth_diag.jsonl to append one JSON line per
   interesting network event (any URL mentioning login/oauth, and any
   request/response carrying an `authorization` header). It answers the
   question "where does the access token actually show up?" with evidence
   instead of guesses. The file stays inside the container.

USAGE (from the host, applying the captured session)
----------------------------------------------------
   docker cp o2cloud-webdav:/tmp/capout.json ./session.json
   curl -s -b adm.cookies -H "x-csrf-token: $CSRF" -H "Content-Type: application/json" \
        -d @session.json http://localhost:8088/api/admin/o2/import
   docker restart o2cloud-webdav   # MANDATORY: clears the in-memory _expired_key
   # verify: PROPFIND /dav/encrypted -> 207

NOTES
-----
* Only ONE capture may run at a time (it holds the persistent profile).
* `dead_key` args are the previously-expired validationKey(s) to reject, so the
  script does not "capture" the stale key the SPA keeps in its cookie/store.
* The container image has no `ps` nor `pkill`: enumerate processes through
  /proc/*/comm and kill by PID.
"""
from __future__ import annotations

import asyncio
import glob
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from urllib.parse import urlparse

VALIDATION_RE = re.compile(r"validationkey[^A-Za-z0-9._-]+([A-Za-z0-9._-]{8,})", re.IGNORECASE)
COOKIE_HOSTS = ("micloud.movistar.es", "o2online.es", "movistar.es")
TIMEOUT_SECONDS = 600
STALE_PROBE_SECONDS = 12
# Once a fresh validationKey is seen, keep listening a bit longer so the
# /login/oauth response (bundle + encryption token) can land before we write.
OAUTH_GRACE_SECONDS = 25
OAUTH_URL_SUFFIX = "/login/oauth"

BOOTSTRAP = r"""
(() => {
  try {
    window.__o2SeenUrls = [];
    const rec = (u) => { try { window.__o2SeenUrls.push(String(u && u.url ? u.url : u)); } catch (e) {} };
    const of = window.fetch;
    if (of) window.fetch = function (...a) { try { rec(a[0]); } catch (e) {} return of.apply(this, a); };
    const oo = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (m, u, ...r) { try { rec(u); } catch (e) {} return oo.call(this, m, u, ...r); };
  } catch (e) {}
})();
"""

CAPTURE = r"""
(() => {
  const out = { validationKey: null, userAgent: navigator.userAgent, storage: [], seenUrls: [] };
  const m = /validationkey[^A-Za-z0-9._-]+([A-Za-z0-9._-]{8,})/i;
  try {
    for (const s of [localStorage, sessionStorage]) {
      for (let i = 0; i < s.length; i++) {
        const k = s.key(i), v = s.getItem(k) || "";
        out.storage.push(k + "=" + v);
        const hit = v.match(m) || k.match(m);
        if (hit) out.validationKey = hit[1];
      }
    }
  } catch (e) {}
  try { document.cookie.split(";").forEach((c) => { const h = c.match(m); if (h) out.validationKey = h[1]; }); } catch (e) {}
  try { out.seenUrls = window.__o2SeenUrls || []; } catch (e) {}
  return out;
})();
"""


def normalize_oauth_bundle(value: str) -> str:
    """Same rule as o2gateway.o2.session.normalize_oauth_bundle.

    "oauth <credential>" -> "<credential>"
    "<credential>"       -> "<credential>"
    "<other> <x>"        -> "" (not an oauth credential)
    """
    raw = (value or "").strip()
    if not raw:
        return ""
    scheme, separator, credential = raw.partition(" ")
    if separator and scheme.lower() == "oauth":
        return credential.strip()
    return raw if not separator else ""


def is_oauth_login_url(raw_url: str) -> bool:
    """True for the login/oauth endpoint (same test as the gateway)."""
    try:
        return urlparse(raw_url).path.rstrip("/").endswith(OAUTH_URL_SUFFIX)
    except Exception:
        return False


def find_chromium():
    hits = sorted(glob.glob("/ms-playwright/chromium-*/chrome-linux*/chrome"))
    return hits[0] if hits else None


def main():
    if len(sys.argv) < 3:
        print("usage: o2-session-capture.py <dead_key[,key2,...]> <output.json>", file=sys.stderr)
        return 2
    dead_keys = {k for k in re.split(r"[,\s]+", sys.argv[1]) if k}
    out_path = sys.argv[2]
    return asyncio.run(run(dead_keys, out_path))


async def run(dead_keys, out_path):
    from playwright.async_api import async_playwright

    config_dir = os.environ.get("CONFIG_DIR", "/config")
    provider = os.environ.get("CLOUD_PROVIDER", "movistar").lower()
    profile = os.path.join(config_dir, "playwright-o2-profile", provider)
    login_url = (
        os.environ.get("MOVISTAR_LOGIN_URL")
        or os.environ.get("O2_LOGIN_URL")
        or "https://micloud.movistar.es/"
    )
    heartbeat = os.environ.get("O2_CAPTURE_HEARTBEAT", "/tmp/cap_heartbeat")
    diag_path = os.environ.get("O2_CAPTURE_DIAG", "")
    chromium = find_chromium()

    def beat(state, **extra):
        try:
            payload = {"state": state, "ts": datetime.now(timezone.utc).isoformat()}
            payload.update(extra)
            with open(heartbeat, "w") as fh:
                json.dump(payload, fh)
        except Exception:
            pass

    def diag(**fields):
        if not diag_path:
            return
        try:
            fields.setdefault("ts", datetime.now(timezone.utc).isoformat())
            with open(diag_path, "a") as fh:
                fh.write(json.dumps(fields, sort_keys=True) + "\n")
        except Exception:
            pass

    beat("starting", profile=profile, chromium=chromium)
    captured = {
        "key": None,
        "key_source": "",
        "device_id": "",
        "device_name": "",
        "oauth": "",
        "oauth_source": "",
        "encryption": "",
    }
    device_seen = {"any": "", "on_key": ""}
    tasks: set[asyncio.Task] = set()

    async with async_playwright() as p:
        ctx = await p.chromium.launch_persistent_context(
            profile,
            headless=False,
            executable_path=chromium,
            viewport={"width": 1280, "height": 800},
            args=["--no-sandbox"],
        )
        await ctx.add_init_script(BOOTSTRAP)
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()

        def set_bundle(raw_value: str, source: str) -> None:
            bundle = normalize_oauth_bundle(raw_value)
            if bundle:
                captured["oauth"] = bundle
                captured["oauth_source"] = source

        def on_request(req):
            try:
                headers = req.headers
                dev = headers.get("x-deviceid") or ""
                if dev and not device_seen["any"]:
                    device_seen["any"] = dev
                if headers.get("x-devicename"):
                    captured["device_name"] = headers["x-devicename"]
                auth = headers.get("authorization", "")
                if auth.lower().startswith("oauth"):
                    set_bundle(auth, "request-header")
                hit = VALIDATION_RE.search(req.url)
                if hit and hit.group(1) not in dead_keys:
                    if not captured["key"]:
                        captured["key"] = hit.group(1)
                        captured["key_source"] = "request-url"
                    # Tie the device id to the request that carries the fresh key:
                    # the device bound at login is the one O2 accepts for this key.
                    if dev:
                        device_seen["on_key"] = dev
                if diag_path and (is_oauth_login_url(req.url) or auth):
                    diag(
                        kind="request",
                        url=req.url,
                        method=req.method,
                        oauth_login=is_oauth_login_url(req.url),
                        auth_scheme=(auth.split(" ")[0] if auth else ""),
                        auth_len=len(auth),
                        has_device_id=bool(dev),
                    )
            except Exception:
                pass

        async def on_response(response):
            try:
                url = response.url
                oauth_login = is_oauth_login_url(url)
                try:
                    headers = await response.all_headers()
                except Exception:
                    headers = {}
                auth = headers.get("authorization", "")
                if auth.lower().startswith("oauth"):
                    set_bundle(auth, "response-header")
                if diag_path and (oauth_login or auth):
                    diag(
                        kind="response",
                        url=url,
                        status=response.status,
                        oauth_login=oauth_login,
                        auth_scheme=(auth.split(" ")[0] if auth else ""),
                        auth_len=len(auth),
                    )
                if not oauth_login:
                    return
                try:
                    payload = await response.json()
                except Exception:
                    payload = None
                if not isinstance(payload, dict):
                    return
                data = payload.get("data")
                if not isinstance(data, dict):
                    return
                if diag_path:
                    diag(kind="response-json", url=url, data_keys=sorted(str(k) for k in data))
                token = str(data.get("access_token") or data.get("accessToken") or "")
                if token:
                    set_bundle(token, "response-json-access_token")
                key = str(data.get("validationkey") or data.get("validationKey") or "")
                if key and key not in dead_keys:
                    captured["key"] = key
                    captured["key_source"] = "response-json-validationkey"
                enc = str(data.get("encryption-token") or data.get("encryptionToken") or "")
                if enc:
                    captured["encryption"] = enc
            except Exception:
                pass

        def schedule(coro):
            task = asyncio.create_task(coro)
            tasks.add(task)
            task.add_done_callback(tasks.discard)

        page.on("request", on_request)
        page.on("response", lambda response: schedule(on_response(response)))

        def current_device_id():
            return device_seen["on_key"] or device_seen["any"]

        async def drain():
            if tasks:
                await asyncio.gather(*list(tasks), return_exceptions=True)

        async def capture_state():
            try:
                st = await page.evaluate(CAPTURE)
            except Exception:
                st = {}
            key = st.get("validationKey")
            if not key:
                for u in st.get("seenUrls") or []:
                    hit = VALIDATION_RE.search(u)
                    if hit:
                        key = hit.group(1)
                        break
            if not key:
                for blob in st.get("storage") or []:
                    hit = VALIDATION_RE.search(blob)
                    if hit:
                        key = hit.group(1)
                        break
            if key in dead_keys:
                key = None
            return st, key

        async def build_session(key, st):
            cookies = []
            try:
                for c in await ctx.cookies():
                    dom = c.get("domain") or ""
                    if any(h in dom for h in COOKIE_HOSTS) and c.get("name") and c.get("value"):
                        cookies.append(
                            {
                                "name": c["name"],
                                "value": c["value"],
                                "domain": dom,
                                "path": c.get("path") or "/",
                            }
                        )
            except Exception:
                pass
            return {
                "validationKey": key,
                "cookies": cookies,
                "userAgent": (st or {}).get("userAgent") or "",
                "oauthBundle": captured["oauth"],
                "deviceId": current_device_id(),
                "deviceName": captured["device_name"] or "",
                "encryptionToken": captured["encryption"] or "",
                "createdAt": datetime.now(timezone.utc).isoformat(),
            }

        beat("waiting_user_login", url=login_url)
        try:
            await page.goto(login_url, wait_until="domcontentloaded")
        except Exception as exc:
            # net::ERR_CERT_VERIFIER_CHANGED and friends are transient.
            beat("goto_failed", error=str(exc))

        start = time.time()
        key_found_at = None
        cleared = False
        while time.time() - start < TIMEOUT_SECONDS:
            await asyncio.sleep(2)
            st, key = await capture_state()
            if key and not captured["key"]:
                captured["key"] = key
                captured["key_source"] = captured["key_source"] or "page-state"
            if captured["key"] and captured["key"] not in dead_keys:
                if key_found_at is None:
                    key_found_at = time.time()
                # Give the /login/oauth response time to deliver the bundle.
                if captured["oauth"] or (time.time() - key_found_at) >= OAUTH_GRACE_SECONDS:
                    await drain()
                    session = await build_session(captured["key"], st)
                    with open(out_path, "w") as fh:
                        json.dump(session, fh)
                    beat(
                        "success",
                        validationKey=captured["key"],
                        output=out_path,
                        cookies=len(session["cookies"]),
                        oauthCaptured=bool(session["oauthBundle"]),
                        keySource=captured["key_source"],
                        oauthSource=captured["oauth_source"],
                    )
                    print(
                        json.dumps(
                            {
                                "ok": True,
                                "validationKey": captured["key"],
                                "cookies": len(session["cookies"]),
                                "deviceId": session["deviceId"],
                                "oauthBundle": bool(session["oauthBundle"]),
                                "oauthSource": captured["oauth_source"],
                                "encryptionToken": bool(session["encryptionToken"]),
                            }
                        )
                    )
                    await ctx.close()
                    return 0
            if not cleared and (time.time() - start) >= STALE_PROBE_SECONDS:
                beat("stale_clearing")
                try:
                    await ctx.clear_cookies()
                except Exception:
                    pass
                try:
                    await page.reload(wait_until="domcontentloaded")
                except Exception:
                    pass
                cleared = True
                beat("waiting_user_login", note="cookies cleared, login required")

        await drain()
        beat("timeout", oauthCaptured=bool(captured["oauth"]))
        print(json.dumps({"ok": False, "error": "timeout", "oauthCaptured": bool(captured["oauth"])}))
        await ctx.close()
        return 1


if __name__ == "__main__":
    sys.exit(main())
