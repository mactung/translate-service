"""
Download NLLB-200-distilled-600M from Hugging Face and convert it to ctranslate2
int8 format. Run once during install; idempotent — re-running with --force redoes
the conversion in place.

Usage:
    python scripts/download_model.py
    python scripts/download_model.py --force
"""

import argparse
import os
import shutil
import subprocess
import sys

HF_MODEL_NAME = "Helsinki-NLP/opus-mt-en-vi"
OUT_DIR = os.environ.get(
    "MODEL_DIR",
    "/root/apps/translate-service/models/opus-mt-en-vi-ct2",
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true", help="overwrite existing converted model")
    args = parser.parse_args()

    if os.path.isdir(OUT_DIR) and os.path.isfile(os.path.join(OUT_DIR, "model.bin")):
        if not args.force:
            print(f"[skip] converted model already at {OUT_DIR}")
            return 0
        print(f"[force] removing {OUT_DIR}")
        shutil.rmtree(OUT_DIR)

    os.makedirs(os.path.dirname(OUT_DIR), exist_ok=True)

    # Resolve the converter executable next to the current python interpreter
    # so the script works under any venv layout (not just PATH-aware shells).
    venv_bin = os.path.dirname(sys.executable)
    converter = os.path.join(venv_bin, "ct2-transformers-converter")
    if not os.path.isfile(converter):
        fallback = shutil.which("ct2-transformers-converter")
        if not fallback:
            print(
                f"[error] ct2-transformers-converter not found at {converter} or on PATH",
                file=sys.stderr,
            )
            return 1
        converter = fallback

    # OPUS-MT (MarianMT) ships SentencePiece source/target models (source.spm,
    # target.spm) and vocab.json. It does NOT ship special_tokens_map.json.
    cmd = [
        converter,
        "--model", HF_MODEL_NAME,
        "--output_dir", OUT_DIR,
        "--quantization", "int8",
        "--copy_files", "tokenizer_config.json", "source.spm", "target.spm", "vocab.json", "generation_config.json",
    ]
    print("running:", " ".join(cmd))
    return subprocess.call(cmd)


if __name__ == "__main__":
    sys.exit(main())
