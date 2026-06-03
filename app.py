"""
FastAPI translation service backed by Helsinki-NLP/opus-mt-en-vi via ctranslate2.

Drop-in replacement for the previous LibreTranslate endpoint. Same JSON contract:
    POST /translate  { q, source, target, format } -> { translatedText }
    GET  /languages  -> [{code, name, targets}]
    GET  /health     -> { ok: true }

OPUS-MT is a dedicated en->vi MarianMT model (~75M params). Much faster than the
multilingual NLLB-600M on CPU (~150-400 ms vs 1-4 s) at comparable quality for
this single pair. Only en->vi is supported today; flipping direction would need
the sibling opus-mt-vi-en model.

We use the SentencePiece source.spm / target.spm files directly (the ones that
ship with the OPUS-MT repo and are copied during ct2 conversion). The HF Marian
tokenizer's convert_ids_to_tokens / decode roundtrip mangles spacing for some
inputs, so going straight to SentencePiece is both faster and more reliable.
"""

import logging
import os
from typing import List

import ctranslate2
import sentencepiece as spm
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("translate-service")

MODEL_DIR = os.getenv("MODEL_DIR", "/root/apps/translate-service/models/opus-mt-en-vi-ct2")
INTER_THREADS = int(os.getenv("INTER_THREADS", "1"))
INTRA_THREADS = int(os.getenv("INTRA_THREADS", "4"))
BEAM_SIZE = int(os.getenv("BEAM_SIZE", "1"))
MAX_INPUT_CHARS = int(os.getenv("MAX_INPUT_CHARS", "5000"))

SUPPORTED_PAIR = ("en", "vi")  # OPUS-MT model is direction-specific.

log.info("loading ctranslate2 model from %s", MODEL_DIR)
translator = ctranslate2.Translator(
    MODEL_DIR,
    device="cpu",
    compute_type="int8",
    inter_threads=INTER_THREADS,
    intra_threads=INTRA_THREADS,
)

src_spm = spm.SentencePieceProcessor()
src_spm.Load(os.path.join(MODEL_DIR, "source.spm"))
tgt_spm = spm.SentencePieceProcessor()
tgt_spm.Load(os.path.join(MODEL_DIR, "target.spm"))
log.info("model + tokenizers ready")


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
    return [
        {"code": "en", "name": "English", "targets": ["vi"]},
        {"code": "vi", "name": "Vietnamese", "targets": []},
    ]


@app.post("/translate", response_model=TranslateResp)
def translate(req: TranslateReq) -> TranslateResp:
    if (req.source, req.target) != SUPPORTED_PAIR:
        raise HTTPException(
            status_code=400,
            detail=f"only {SUPPORTED_PAIR[0]}->{SUPPORTED_PAIR[1]} is supported, got {req.source}->{req.target}",
        )
    if len(req.q) > MAX_INPUT_CHARS:
        raise HTTPException(status_code=413, detail=f"q exceeds {MAX_INPUT_CHARS} chars")

    source_pieces = src_spm.EncodeAsPieces(req.q)
    results = translator.translate_batch(
        [source_pieces],
        beam_size=BEAM_SIZE,
        max_decoding_length=512,
    )
    target_pieces = results[0].hypotheses[0]
    text = tgt_spm.DecodePieces(target_pieces)
    return TranslateResp(translatedText=text)
