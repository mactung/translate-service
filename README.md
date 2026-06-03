# translate-service

Self-hosted LibreTranslate (Argos NMT) deployed natively (no Docker) on an Ubuntu VPS. Replaces Google Cloud Translation as the primary provider for shadowing-speak when the target language is Vietnamese; Google stays wired in as a fallback and as the primary for every other locale.

## Why

Google Cloud Translation costs $20 / 1M characters. Vocab + sentence + short-story translations on this project burn through that quickly. Hosting Argos on a server we already own moves the marginal cost to ~$0 per character; we pay only for VPS time we'd be paying for anyway.

## Hardware target

Contabo VPS: **4 GB RAM, 4 vCPU, Ubuntu 24+**. Scoped to a single language pair (en→vi):

| Component                       | RAM      |
| ------------------------------- | -------- |
| LibreTranslate gunicorn process | ~300 MB  |
| Argos en→vi model (loaded)      | ~700 MB  |
| OS + nginx overhead             | ~500 MB  |
| **Total**                       | ~1.5 GB  |

That leaves >2 GB headroom. The systemd unit caps the service at 2 GB via `MemoryMax`. Performance:

- First request after start: 5–15 s (cold model load).
- Subsequent requests: 100–500 ms per sentence.
- The upstream DB cache makes each `(text, "vi")` pair pay the cold cost at most once.

Other 12 target languages (ja, ko, zh, hi, ar, fr, pt, th, it, de, ru) bypass this service entirely and hit Google in the upstream client — no Argos model is loaded for them, so their RAM cost is zero.

## Layout on the server

```
/root/apps/translate-service/        ← this repo
├── install.sh                       ← native installer (venv + pip + systemd)
├── systemd/libretranslate.service   ← unit file (copied to /etc/systemd/system/)
├── nginx/
│   ├── translate.shadowingenglish.com.conf  ← HTTP-only site config
│   └── install.sh                            ← copies into /etc/nginx/sites-*
└── venv/                            ← created by install.sh
```

## Deploy

On the server, as root:

```sh
cd /root/apps/translate-service
git pull
./install.sh           # installs LibreTranslate, registers + starts the systemd service
./nginx/install.sh     # publishes the nginx site config and reloads nginx
```

First boot downloads the Argos en→vi package (~250 MB). Allow 1–3 minutes. `install.sh` waits on `/languages` before returning and prints a smoke-test translation.

## API contract (used by shadowing-speak)

`POST /translate` with JSON `{ q, source: "en", target: "vi", format: "text" }` returns `{ translatedText }`. No API key required by default.

## Operational notes

- **Logs**: `journalctl -u libretranslate -f`
- **Restart**: `systemctl restart libretranslate`
- **Status**: `systemctl status libretranslate`
- **Languages loaded**: `curl http://127.0.0.1:5050/languages`
- **Smoke test (local)**: `curl -X POST http://127.0.0.1:5050/translate -H 'Content-Type: application/json' -d '{"q":"hello","source":"en","target":"vi","format":"text"}'`
- **Smoke test (public)**: `curl -X POST http://translate.shadowingenglish.com/translate -H 'Content-Type: application/json' -d '{"q":"hello","source":"en","target":"vi","format":"text"}'`
- **Upgrade**: `./install.sh --reinstall` then `systemctl restart libretranslate`
- **Memory pressure**: if the unit gets OOM-killed, lower workers/threads in `systemd/libretranslate.service` rather than raising `MemoryMax` past 2.5 GB (leave room for nginx + OS on the 4 GB box).

## Upstream integration

`shadowing-speak/src/lib/translator.ts` reads `LIBRETRANSLATE_URL` (e.g. `http://translate.shadowingenglish.com`) and optional `LIBRETRANSLATE_API_KEY`. Routing logic:

- `lang === "vi"` → call Libre. If it returns null or throws, fall back to Google.
- `lang !== "vi"` → call Google directly. Libre is skipped (its model isn't loaded anyway).

Add a new language to the Libre path by editing `--load-only` in `systemd/libretranslate.service` and the routing set in `translator.ts`.
