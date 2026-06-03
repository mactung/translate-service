# translate-service

Self-hosted English↔Vietnamese translation backed by **NLLB-200-distilled-600M** (Meta) via **ctranslate2** (int8 CPU inference). Replaces the previous LibreTranslate/Argos deployment with a meaningfully stronger model. Serves the same JSON contract, so the shadowing-speak client (`translator.ts`) needs no changes.

## Why NLLB instead of Argos?

The default Argos en→vi pack is ~250 MB and trained on a generic OPUS corpus. Sentence-level output was acceptable for short, common phrases but degraded quickly on idioms, technical vocabulary, and language-learning jargon (e.g. "shadowing technique" → "kỹ thuật theo bóng"). NLLB-200-distilled-600M is roughly twice the parameter count, trained on a much larger multilingual corpus, and the int8-quantized ctranslate2 build runs comfortably on a 4 GB CPU box.

## Hardware target

Contabo VPS: **4 GB RAM, 4 vCPU, Ubuntu 24+**.

| Component                       | RAM      |
| ------------------------------- | -------- |
| uvicorn + FastAPI               | ~80 MB   |
| ctranslate2 NLLB int8 (loaded)  | ~1.4 GB  |
| Python overhead                 | ~200 MB  |
| OS + nginx                      | ~500 MB  |
| **Total**                       | ~2.2 GB  |

`systemd` caps the unit at 2500 MB via `MemoryMax`. The 4 GB box keeps ~1.5 GB headroom for nginx + the OS.

Performance on 4 vCPU CPU-only inference:

- First request after start: ~3–5 s (model warm-up).
- Subsequent requests: 200–800 ms per sentence depending on length.
- `OMP_NUM_THREADS=4` and `intra_threads=4` so a single translate call uses all 4 cores.
- The upstream DB cache makes each `(text, "vi")` pair pay the model cost at most once.

The service only loads en↔vi today. Adding another locale is a one-line change in `LANG_MAP` (and rolling out a new model package would also work — the NLLB checkpoint already knows 200 languages).

## Layout on the server

```
/root/apps/translate-service/
├── app.py                                ← FastAPI app (single endpoint)
├── requirements.txt                      ← pinned python deps
├── install.sh                            ← native installer
├── scripts/download_model.py             ← downloads + converts NLLB to ctranslate2 int8
├── systemd/translate-service.service     ← unit copied to /etc/systemd/system/
├── nginx/translate.shadowingenglish.com.conf
└── venv/                                 ← created by install.sh
└── models/nllb-200-distilled-600M-ct2/   ← converted model files (~1.2 GB on disk)
```

## API contract (unchanged)

`POST /translate` with JSON `{ q, source: "en", target: "vi", format: "text" }` returns `{ translatedText }`. `GET /languages` returns the same shape LibreTranslate did so existing clients keep working. `GET /health` is a tiny liveness probe.

## Deploy

On the server, as root:

```sh
cd /root/apps/translate-service
git pull
./install.sh           # installs deps, downloads/converts model, registers + starts the systemd service
./nginx/install.sh     # publishes the nginx site config and reloads nginx
```

The first install downloads the NLLB checkpoint (~2.3 GB) and converts it to int8 (~1.2 GB on disk). Allow 5–10 minutes.

## Operational notes

- **Logs**: `journalctl -u translate-service -f`
- **Restart**: `systemctl restart translate-service`
- **Status**: `systemctl status translate-service`
- **Smoke test (local)**: `curl -X POST http://127.0.0.1:5050/translate -H 'Content-Type: application/json' -d '{"q":"hello","source":"en","target":"vi","format":"text"}'`
- **Smoke test (public)**: `curl -X POST https://translate.shadowingenglish.com/translate -H 'Content-Type: application/json' -d '{"q":"hello","source":"en","target":"vi","format":"text"}'`
- **Upgrade deps**: `./install.sh --reinstall-deps`
- **Re-convert model**: `./install.sh --reconvert-model`
- **Disk reclaim**: deleting `~/.cache/huggingface` after install is safe — the converted CT2 model is fully self-contained.

## Upstream integration

`shadowing-speak/src/lib/translator.ts` reads `LIBRETRANSLATE_URL` (e.g. `https://translate.shadowingenglish.com`) and optional `LIBRETRANSLATE_API_KEY`. (The env name still says "libretranslate" for backwards compatibility; the on-the-wire JSON shape is identical, so no client change is needed.) Routing logic:

- `lang === "vi"` → call this service. If it returns null or throws, fall back to Google.
- `lang !== "vi"` → call Google directly.

Add a new target language by extending `LANG_MAP` in `app.py` and the routing set in `translator.ts`.
