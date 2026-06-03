"""
FastAPI translation service backed by NLLB-200-distilled-600M via ctranslate2.

Drop-in replacement for the previous LibreTranslate endpoint. Same JSON contract:
    POST /translate  { q, source, target, format } -> { translatedText }
    GET  /languages  -> [{code, name, targets}]
    GET  /health     -> { ok: true }

The model is loaded once at startup. RAM is ~1.5 GB with int8 quantization on CPU.
"""

import logging
import os
from typing import List

import ctranslate2
import transformers
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("translate-service")

MODEL_DIR = os.getenv("MODEL_DIR", "/root/apps/translate-service/models/nllb-200-distilled-600M-ct2")
HF_MODEL_NAME = os.getenv("HF_MODEL_NAME", "facebook/nllb-200-distilled-600M")
INTER_THREADS = int(os.getenv("INTER_THREADS", "1"))
INTRA_THREADS = int(os.getenv("INTRA_THREADS", "4"))
BEAM_SIZE = int(os.getenv("BEAM_SIZE", "4"))
MAX_INPUT_CHARS = int(os.getenv("MAX_INPUT_CHARS", "5000"))

# Project's `lang` codes -> NLLB BCP-47-ish codes.
LANG_MAP = {
    "en": "eng_Latn",
    "vi": "vie_Latn",
}

log.info("loading ctranslate2 model from %s", MODEL_DIR)
translator = ctranslate2.Translator(
    MODEL_DIR,
    device="cpu",
    compute_type="int8",
    inter_threads=INTER_THREADS,
    intra_threads=INTRA_THREADS,
)
log.info("loading tokenizer %s", HF_MODEL_NAME)
tokenizer = transformers.AutoTokenizer.from_pretrained(HF_MODEL_NAME)
log.info("model + tokenizer ready")


class TranslateReq(BaseModel):
    q: str = Field(..., min_length=1)
    source: str
    target: str
    format: str = "text"


class TranslateResp(BaseModel):
    translatedText: str


app = FastAPI(title="translate-service", docs_url=None, redoc_url=None)


@app.get("/health")
def health() -> dict:
    return {"ok": True}


@app.get("/languages")
def languages() -> List[dict]:
    codes = list(LANG_MAP.keys())
    return [
        {"code": "en", "name": "English", "targets": codes},
        {"code": "vi", "name": "Vietnamese", "targets": codes},
    ]


@app.post("/translate", response_model=TranslateResp)
def translate(req: TranslateReq) -> TranslateResp:
    if req.source not in LANG_MAP:
        raise HTTPException(status_code=400, detail=f"unsupported source: {req.source}")
    if req.target not in LANG_MAP:
        raise HTTPException(status_code=400, detail=f"unsupported target: {req.target}")
    if req.source == req.target:
        return TranslateResp(translatedText=req.q)
    if len(req.q) > MAX_INPUT_CHARS:
        raise HTTPException(status_code=413, detail=f"q exceeds {MAX_INPUT_CHARS} chars")

    src_lang = LANG_MAP[req.source]
    tgt_lang = LANG_MAP[req.target]

    tokenizer.src_lang = src_lang
    source_tokens = tokenizer.convert_ids_to_tokens(tokenizer.encode(req.q))
    target_prefix = [tgt_lang]

    results = translator.translate_batch(
        [source_tokens],
        target_prefix=[target_prefix],
        beam_size=BEAM_SIZE,
        max_decoding_length=512,
    )
    target_tokens = results[0].hypotheses[0][1:]  # strip target_prefix
    target_ids = tokenizer.convert_tokens_to_ids(target_tokens)
    text = tokenizer.decode(target_ids, skip_special_tokens=True)
    return TranslateResp(translatedText=text)
