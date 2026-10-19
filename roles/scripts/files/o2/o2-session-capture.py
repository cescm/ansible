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
* The gateway cannot silently renew a genuinely expired session: our sessions
  have no oauth bundle (can_refresh=False) and Movistar re-login is OTP-gated,
  so a human must complete the login.
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

VALIDATION_RE = re.compile(r"validationkey[^A-Za-z0-9._-]+([A-Za-z0-9._-]{8,})", re.IGNORECASE)
COOKIE_HOSTS = ("micloud.movistar.es", "o2online.es", "movistar.es")
TIMEOUT_SECONDS = 600
STALE_PROBE_SECONDS = 12

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
    chromium = find_chromium()

    def beat(state, **extra):
        try:
            payload = {"state": state, "ts": datetime.now(timezone.utc).isoformat()}
            payload.update(extra)
            with open(heartbeat, "w") as fh:
                json.dump(payload, fh)
        except Exception:
            pass

    beat("starting", profile=profile, chromium=chromium)
    captured = {"key": None, "device_id": "", "device_name": "", "oauth": "", "encryption": ""}
    device_seen = {"any": "", "on_key": ""}

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
                    captured["oauth"] = auth
                hit = VALIDATION_RE.search(req.url)
                if hit and hit.group(1) not in dead_keys:
                    captured["key"] = hit.group(1)
                    # Tie the device id to the request that carries the fresh key:
                    # the device bound at login is the one O2 accepts for this key.
                    if dev:
                        device_seen["on_key"] = dev
            except Exception:
                pass

        page.on("request", on_request)

        def current_device_id():
            return device_seen["on_key"] or device_seen["any"]

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
        await page.goto(login_url, wait_until="domcontentloaded")

        start = time.time()
        cleared = False
        while time.time() - start < TIMEOUT_SECONDS:
            await asyncio.sleep(2)
            st, key = await capture_state()
            if key and not captured["key"]:
                captured["key"] = key
            if captured["key"] and captured["key"] not in dead_keys:
                session = await build_session(captured["key"], st)
                with open(out_path, "w") as fh:
                    json.dump(session, fh)
                beat("success", validationKey=captured["key"], output=out_path, cookies=len(session["cookies"]))
                print(json.dumps({"ok": True, "validationKey": captured["key"], "cookies": len(session["cookies"]), "deviceId": session["deviceId"]}))
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

        beat("timeout")
        print(json.dumps({"ok": False, "error": "timeout"}))
        await ctx.close()
        return 1


if __name__ == "__main__":
    sys.exit(main())
