"""File processing tools: image modification, analysis, audio transcription, document extraction.

These tools download attached files from their presigned URLs, process them
using OpenAI APIs + Pillow, and upload the results back to the Phoenix API
as task output files.
"""

import base64
import io
import re
from typing import Any

import httpx
import structlog
from PIL import Image, ImageEnhance, ImageFilter

from app import llm
from app.tools.registry import RunContext, tool

log = structlog.get_logger()


async def _download(url: str) -> bytes:
    """Download a file from a presigned URL."""
    async with httpx.AsyncClient(timeout=30, follow_redirects=True) as client:
        resp = await client.get(url)
        resp.raise_for_status()
        return resp.content


@tool("analyze_file")
async def analyze_file(params: dict[str, Any], ctx: RunContext) -> Any:
    """Analyze any file (image, document) using GPT-4 Vision and return a text description."""
    question = params.get("question") or ctx.task_description or "Describe this file in detail."
    file_url = params.get("file_url")

    if not file_url:
        return {"analysis": "", "error": "No file URL provided. Ensure a file is attached to the task."}

    if not llm.is_configured():
        return {"analysis": "(offline mode — cannot analyze file)", "note": "offline fallback"}

    analysis = await llm.vision(
        system="You are a helpful assistant. Analyze the provided file/image and answer the user's question thoroughly. Reply in the same language as the question.",
        user_text=question,
        image_url=file_url,
        usage=ctx.usage,
        max_tokens=1500,
    )
    return {"analysis": analysis, "file_url": file_url}


@tool("transform_image")
async def transform_image(params: dict[str, Any], ctx: RunContext) -> Any:
    """Transform/modify an image based on instructions. Supports color changes, filters,
    adjustments, format conversion, and creative modifications via DALL-E."""
    instruction = params.get("instruction") or ctx.task_description or ""
    file_url = params.get("file_url")

    if not file_url:
        return {"error": "No image URL provided. Ensure an image file is attached to the task."}

    if not llm.is_configured():
        return {"error": "OpenAI API key required for image processing.", "note": "offline fallback"}

    try:
        image_bytes = await _download(file_url)
    except Exception as exc:
        return {"error": f"Could not download the image: {exc}"}

    img = Image.open(io.BytesIO(image_bytes))
    original_format = img.format or "PNG"

    # The image APIs only accept PNG/JPEG/WebP. Anything else (.ico, .bmp,
    # .gif, .tiff…) is transparently re-encoded to PNG so the user's request
    # succeeds instead of erroring on a format detail.
    if original_format not in ("PNG", "JPEG", "WEBP"):
        buf = io.BytesIO()
        img.convert("RGBA").save(buf, format="PNG")
        image_bytes = buf.getvalue()
        img = Image.open(io.BytesIO(image_bytes))
        original_format = "PNG"

    source_mime = f"image/{original_format.lower()}"

    plan = await llm.chat_json(
        system="""You decide HOW to process an image. Given the user instruction, respond with a JSON object:
{"method": "ai_edit"|"pillow", "edit_prompt": "...", "pillow_ops": [...], "output_format": "PNG"|"JPEG"}

method=ai_edit (DEFAULT — pick this whenever in doubt): a generative image
model edits the original image following edit_prompt. Use it for anything
visual or subjective: recoloring/restyling ("make it orange", "more modern"),
redesigns, style changes, adding/removing/replacing elements, backgrounds,
lighting, textures, "make it look like…". Write edit_prompt as a precise,
self-contained instruction in English describing the desired result while
preserving everything the user didn't ask to change.

method=pillow ONLY for purely mechanical operations where pixel-exact
determinism matters and no aesthetic judgement is involved: resize, rotate,
flip, format conversion, blur, sharpen, brightness/contrast adjustments.
Never use pillow tints or hue shifts to approximate a requested look — that
produces a cheap color-filter result. pillow_ops (only when method=pillow):
- {"op": "grayscale"}
- {"op": "brightness", "factor": float} — 1.0 = original, >1 brighter
- {"op": "contrast", "factor": float}
- {"op": "blur", "radius": int}
- {"op": "sharpen"}
- {"op": "resize", "width": int, "height": int}
- {"op": "rotate", "degrees": int}
- {"op": "flip", "direction": "horizontal"|"vertical"}""",
        user=f"Instruction: {instruction}\nImage size: {img.size}\nImage mode: {img.mode}",
        usage=ctx.usage,
        max_tokens=400,
    )

    method = plan.get("method", "ai_edit")
    output_format = plan.get("output_format", original_format).upper()
    if output_format not in ("PNG", "JPEG", "WEBP"):
        output_format = "PNG"

    result_bytes: bytes | None = None
    description = ""

    if method == "ai_edit":
        edit_prompt = plan.get("edit_prompt") or instruction
        result_bytes = await llm.edit_image(
            image_bytes, edit_prompt, usage=ctx.usage, mime_type=source_mime
        )
        if result_bytes:
            output_format = "PNG"  # gpt-image-1 returns PNG
            description = f"AI-edited the image: {edit_prompt[:150]}"
        else:
            # Editing unavailable (model access, size limits…) — regenerate
            # from a vision description so the request still lands, which
            # beats degrading to a color filter.
            log.warning("ai_edit_unavailable_falling_back", run_id=ctx.run_id)
            fallback_prompt = (
                f"Recreate this exact image with the following change applied: {edit_prompt}"
            )
            result_bytes = await llm.generate_image(fallback_prompt, usage=ctx.usage)
            if result_bytes:
                output_format = "PNG"
                description = f"Regenerated the image with the requested change: {edit_prompt[:120]}"
            else:
                return {
                    "error": "AI image editing failed. Try rephrasing the instruction or retry later."
                }

    elif method == "pillow":
        ops = plan.get("pillow_ops") or []
        processed = img.copy()
        if processed.mode not in ("RGB", "RGBA"):
            processed = processed.convert("RGBA")

        applied: list[str] = []
        for op_spec in ops:
            op = op_spec.get("op", "")
            try:
                if op in ("colorize", "tint"):
                    color_hex = op_spec.get("color", "#00FF00")
                    hue_shift = op_spec.get("hue_shift", 0)

                    if hue_shift and not op_spec.get("color"):
                        hsv = processed.convert("HSV")
                        h, s, v = hsv.split()
                        h = h.point(lambda p, hs=hue_shift: (p + hs) % 256)
                        processed = Image.merge("HSV", (h, s, v)).convert(processed.mode)
                        applied.append(f"hue shifted by {hue_shift}°")
                    else:
                        if color_hex.startswith("#") and len(color_hex) >= 7:
                            r = int(color_hex[1:3], 16)
                            g = int(color_hex[3:5], 16)
                            b = int(color_hex[5:7], 16)
                        else:
                            r, g, b = 0, 255, 0
                        overlay = Image.new("RGBA", processed.size, (r, g, b, 80))
                        if processed.mode == "RGBA":
                            processed = Image.alpha_composite(processed, overlay)
                        else:
                            processed = Image.blend(
                                processed.convert("RGBA"),
                                Image.new("RGBA", processed.size, (r, g, b, 255)),
                                0.3,
                            )
                        applied.append(f"tinted with {color_hex}")

                elif op == "grayscale":
                    processed = processed.convert("L").convert(processed.mode)
                    applied.append("converted to grayscale")
                elif op == "brightness":
                    factor = float(op_spec.get("factor", 1.2))
                    processed = ImageEnhance.Brightness(processed).enhance(factor)
                    applied.append(f"brightness ×{factor}")
                elif op == "contrast":
                    factor = float(op_spec.get("factor", 1.2))
                    processed = ImageEnhance.Contrast(processed).enhance(factor)
                    applied.append(f"contrast ×{factor}")
                elif op == "blur":
                    radius = int(op_spec.get("radius", 2))
                    processed = processed.filter(ImageFilter.GaussianBlur(radius))
                    applied.append(f"blur radius {radius}")
                elif op == "sharpen":
                    processed = processed.filter(ImageFilter.SHARPEN)
                    applied.append("sharpened")
                elif op == "resize":
                    w = int(op_spec.get("width", processed.width))
                    h = int(op_spec.get("height", processed.height))
                    processed = processed.resize((w, h), Image.LANCZOS)
                    applied.append(f"resized to {w}×{h}")
                elif op == "rotate":
                    degrees = int(op_spec.get("degrees", 90))
                    processed = processed.rotate(degrees, expand=True)
                    applied.append(f"rotated {degrees}°")
                elif op == "flip":
                    direction = op_spec.get("direction", "horizontal")
                    if direction == "horizontal":
                        processed = processed.transpose(Image.FLIP_LEFT_RIGHT)
                    else:
                        processed = processed.transpose(Image.FLIP_TOP_BOTTOM)
                    applied.append(f"flipped {direction}")
            except Exception as e:
                log.warning("pillow_op_failed", op=op, error=str(e))

        buf = io.BytesIO()
        save_mode = "RGB" if output_format == "JPEG" else processed.mode
        processed.convert(save_mode).save(buf, format=output_format)
        result_bytes = buf.getvalue()
        description = f"Applied: {', '.join(applied) if applied else 'no changes'}."

    elif method == "dalle":
        # Legacy plan shape — treat as text-to-image generation.
        dalle_prompt = plan.get("dalle_prompt") or f"Based on the original image: {instruction}"
        result_bytes = await llm.generate_image(dalle_prompt, usage=ctx.usage)
        if result_bytes:
            description = f"Generated new image: {dalle_prompt[:100]}"
        else:
            return {"error": "Image generation failed. Try rephrasing the instruction."}

    if result_bytes is None:
        return {"error": "Image processing produced no output."}

    ext = output_format.lower()
    mime = f"image/{ext}"
    original_name = params.get("original_filename") or "image"
    clean_name = re.sub(r"\.[^.]+$", "", original_name)
    filename = f"{clean_name}-modified.{ext}"

    if ctx.phoenix:
        saved = await ctx.phoenix.save_task_output(
            ctx.workspace_id,
            ctx.task_id,
            filename,
            base64.b64encode(result_bytes).decode(),
            mime_type=mime,
            encoding="base64",
        )
        if saved:
            return {"filename": filename, "description": description, "size_bytes": len(result_bytes)}

    return {"error": "Could not save the processed image."}


@tool("transcribe_audio")
async def transcribe_audio(params: dict[str, Any], ctx: RunContext) -> Any:
    """Transcribe an audio file using OpenAI Whisper."""
    file_url = params.get("file_url")

    if not file_url:
        return {"error": "No audio file URL provided."}

    if not llm.is_configured():
        return {"transcript": "", "error": "OpenAI API key required.", "note": "offline fallback"}

    try:
        audio_bytes = await _download(file_url)
    except Exception as exc:
        return {"error": f"Could not download the audio: {exc}"}

    filename = params.get("original_filename") or "audio.mp3"
    transcript = await llm.transcribe_audio_data(audio_bytes, filename, usage=ctx.usage)

    if ctx.phoenix and transcript:
        clean_name = re.sub(r"\.[^.]+$", "", filename)
        out_filename = f"{clean_name}-transcript.txt"
        await ctx.phoenix.save_task_output(
            ctx.workspace_id,
            ctx.task_id,
            out_filename,
            transcript,
            mime_type="text/plain",
        )

    return {"transcript": transcript, "filename": filename}


def _looks_like_text(value: str) -> bool:
    """True when the string is mostly clean text (not decoded binary).

    A raw PDF/binary decoded as UTF-8 is dominated by control chars and the
    U+FFFD replacement character — we must never return that as "extracted
    text": it pollutes the run output and PostgreSQL rejects NUL bytes.
    """
    if not value:
        return False
    sample = value[:4000]
    # Replacement chars mark bytes that couldn't be decoded — lots of them
    # means we decoded binary, not text.
    if sample.count("�") / len(sample) > 0.1:
        return False
    clean = sum(1 for ch in sample if (ch.isprintable() and ch != "�") or ch in "\t\n\r")
    return clean / len(sample) >= 0.85


# Extracted text is truncated so a huge document can't blow the LLM context
# or the run output payload.
_MAX_EXTRACTED_CHARS = 20000


@tool("extract_document_text")
async def extract_document_text(params: dict[str, Any], ctx: RunContext) -> Any:
    """Extract text content from a document (PDF, etc.) for further processing."""
    file_url = params.get("file_url")

    if not file_url:
        return {"error": "No document URL provided."}

    try:
        doc_bytes = await _download(file_url)
    except Exception as exc:
        return {"error": f"Could not download the document: {exc}"}

    filename = params.get("original_filename") or "document"
    is_pdf = filename.lower().endswith(".pdf") or doc_bytes[:5] == b"%PDF-"
    text = ""

    # 1) PyMuPDF (best quality) if available.
    if is_pdf:
        try:
            import fitz  # PyMuPDF — optional

            doc = fitz.open(stream=doc_bytes, filetype="pdf")
            text = "\n\n".join(page.get_text() for page in doc)
            doc.close()
        except ImportError:
            text = ""
        except Exception as exc:
            log.warning("pdf_fitz_failed", error=str(exc))
            text = ""

        # 2) pypdf fallback (pure-python, always available).
        if not text.strip():
            try:
                import io

                from pypdf import PdfReader

                reader = PdfReader(io.BytesIO(doc_bytes))
                text = "\n\n".join((page.extract_text() or "") for page in reader.pages)
            except Exception as exc:
                log.warning("pdf_pypdf_failed", error=str(exc))
                text = ""

    # 3) Plain-text documents: decode, but only keep it if it reads as text.
    if not text.strip():
        decoded = doc_bytes.decode("utf-8", errors="replace")
        if _looks_like_text(decoded):
            text = decoded

    # 4) Last resort: OCR the document with vision (never returns binary).
    if not text.strip() and llm.is_configured():
        try:
            img_url = f"data:application/octet-stream;base64,{base64.b64encode(doc_bytes).decode()}"
            text = await llm.vision(
                system="Extract all visible text from this document. Return only the text.",
                user_text="Extract all text from this document.",
                image_url=img_url,
                usage=ctx.usage,
            )
        except Exception as exc:
            log.warning("document_vision_failed", error=str(exc))

    text = (text or "").strip()
    if not text:
        return {"error": "Could not extract readable text from the document.", "filename": filename}

    return {
        "text": text[:_MAX_EXTRACTED_CHARS],
        "filename": filename,
        "char_count": len(text),
        "truncated": len(text) > _MAX_EXTRACTED_CHARS,
    }
