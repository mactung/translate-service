# translate-service

Self-hosted LibreTranslate (Argos NMT) deployed on a Contabo VPS. Replaces Google Cloud Translation as the primary provider for shadowing-speak; Google stays wired in as a fallback for cold-load gaps and outages.

## Why

Google Cloud Translation costs $20 / 1M characters. Vocab + sentence + short-story translations on this project burn through that quickly. Hosting Argos on a server we already own moves the marginal cost to ~$0 per character; we pay only for VPS time we'd be paying for anyway.

## Hardware target

Contabo VPS: **4 GB RAM, 4 vCPU, Ubuntu 22+**. Scoped to a single language pair (en→vi):

| Component                       | RAM      |
| ------------------------------- | -------- |
| LibreTranslate base process     | ~300 MB  |
| Argos en→vi model (loaded)      | ~700 MB  |
| OS + Docker overhead            | ~500 MB  |
| **Total**                       | ~1.5 GB  |

That leaves >2 GB headroom on a 4 GB box, so the service has room to handle bursts and the container is capped at 2000 MB via `mem_limit`. Performance:

- First request after start: 5–15 s (cold model load).
- Subsequent requests: 100–500 ms per sentence.
- The upstream DB cache makes each `(text, "vi")` pair pay the cost at most once.

Other 12 target languages (ja, ko, zh, hi, ar, fr, pt, th, it, de, ru, en→other) bypass this service entirely and hit Google in the upstream client — no Argos model is loaded for them, so their RAM cost is zero.

## Deploy

```sh
# On the Contabo box, in this directory:
cp .env.example .env       # fill in if you want API-key auth
./deploy.sh                # pulls image, starts container, waits for /languages
```

First boot downloads Argos packages (13 model files, ~2 GB total). Allow 2–3 minutes.

## Reverse proxy

LibreTranslate binds to `127.0.0.1:5050` only. Expose it via nginx or Caddy with TLS. Example nginx block:

```
server {
    listen 443 ssl http2;
    server_name translate.shadowingenglish.com;

    location / {
        proxy_pass http://127.0.0.1:5050;
        proxy_read_timeout 30s;
        client_max_body_size 256k;
    }
}
```

## API contract (used by shadowing-speak)

`POST /translate` with JSON `{ q, source: "en", target, format: "text" }` returns `{ translatedText }`. If `LT_API_KEYS=true`, also send `api_key`.

## Operational notes

- Cold-start a single language pair: `curl -X POST http://127.0.0.1:5050/translate -H 'Content-Type: application/json' -d '{"q":"warm","source":"en","target":"vi","format":"text"}'`
- View loaded languages: `curl http://127.0.0.1:5050/languages`
- Tail logs: `docker logs -f translate-service`
- Restart after config change: `./deploy.sh --no-pull`
- Memory cap is enforced via `mem_limit: 3500m` in compose; if OOM kills happen, drop `LT_LOAD_ONLY` to fewer locales rather than raising the limit (4 GB total minus OS = ~3.5 GB usable).

## Upstream integration

`shadowing-speak/src/lib/translator.ts` reads `LIBRETRANSLATE_URL` (e.g. `https://translate.shadowingenglish.com`) and optional `LIBRETRANSLATE_API_KEY`. Routing logic:

- `lang === "vi"` → call Libre. If it returns null or throws, fall back to Google.
- `lang !== "vi"` → call Google directly. Libre is skipped (its model isn't loaded anyway).

This keeps the Vietnamese translation traffic — the highest volume — off Google's meter, while the long tail of other locales continues on Google where Argos quality and RAM cost don't justify self-hosting yet. Add a new language to the Libre path by extending `LT_LOAD_ONLY` here and the routing check in `translator.ts`.
