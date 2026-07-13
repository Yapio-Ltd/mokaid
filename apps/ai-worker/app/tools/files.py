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
from app.memory import extractors
from app.tools.registry import RunContext, tool

log = structlog.get_logger()

_IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".tiff", ".tif", ".ico")
_AUDIO_EXTS = (".mp3", ".wav", ".m4a", ".ogg", ".flac", ".aac", ".webm", ".mp4", ".mov")
_DOC_EXTS = (
    ".pdf",
    ".txt",
    ".md",
    ".doc",
    ".docx",
    ".rtf",
    ".csv",
    ".tsv",
    ".json",
    ".xlsx",
    ".xlsm",
    ".xls",
    ".pptx",
    ".html",
    ".htm",
)


def _mime_matches(mime: str | None, prefixes: tuple[str, ...]) -> bool:
    if not mime:
        return False
    return any(mime.startswith(p) for p in prefixes)


def _name_matches(name: str | None, exts: tuple[str, ...]) -> bool:
    if not name:
        return False
    lower = name.lower()
    return any(lower.endswith(ext) for ext in exts)


def _pick_attached_file(
    attached: list[dict[str, Any]],
    *,
    mime_prefixes: tuple[str, ...] = (),
    name_exts: tuple[str, ...] = (),
) -> dict[str, Any] | None:
    """Pick the best attached file with a download_url.

    Prefers user input over agent output, then the last matching entry
    (most recent). When mime/name filters are empty, any file with a URL.
    """
    with_url = [f for f in attached if isinstance(f, dict) and f.get("download_url")]
    if not with_url:
        return None

    def matches(f: dict[str, Any]) -> bool:
        if not mime_prefixes and not name_exts:
            return True
        return _mime_matches(f.get("mime_type"), mime_prefixes) or _name_matches(
            f.get("name"), name_exts
        )

    matching = [f for f in with_url if matches(f)] or with_url
    inputs = [f for f in matching if f.get("source") != "agent_output"]
    pool = inputs or matching
    return pool[-1]


def resolve_file_url(
    params: dict[str, Any],
    *,
    mime_prefixes: tuple[str, ...] = (),
    name_exts: tuple[str, ...] = (),
) -> tuple[str | None, str | None]:
    """Return (file_url, original_filename), falling back to _attached_files."""
    file_url = (params.get("file_url") or "").strip() or None
    filename = (params.get("original_filename") or "").strip() or None
    if file_url:
        return file_url, filename

    attached = params.get("_attached_files") or []
    if not isinstance(attached, list):
        return None, filename

    picked = _pick_attached_file(
        attached, mime_prefixes=mime_prefixes, name_exts=name_exts
    )
    if not picked:
        return None, filename
    return picked.get("download_url"), filename or picked.get("name")


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
    file_url, _ = resolve_file_url(params)

    if not file_url:
        return {"analysis": "", "error": "No file URL provided. Ensure a file is attached to the task."}

    from app.config import get_settings

    if not get_settings().openai_api_key:
        return {
            "analysis": "",
            "error": "OpenAI API key required for vision analysis.",
            "note": "offline fallback",
        }

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
    file_url, resolved_name = resolve_file_url(
        params, mime_prefixes=("image/",), name_exts=_IMAGE_EXTS
    )
    if resolved_name and not params.get("original_filename"):
        params = {**params, "original_filename": resolved_name}

    if not file_url:
        return {"error": "No image URL provided. Ensure an image file is attached to the task."}

    # Image edit/generate stays on OpenAI (DALL·E / gpt-image) — DeepSeek and
    # Anthropic do not provide an images API. Check the OpenAI key specifically
    # rather than llm.is_configured(), which is true when only text providers
    # are set.
    from app.config import get_settings

    if not get_settings().openai_api_key:
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
    file_url, resolved_name = resolve_file_url(
        params, mime_prefixes=("audio/", "video/"), name_exts=_AUDIO_EXTS
    )

    if not file_url:
        return {"error": "No audio file URL provided."}

    from app.config import get_settings

    if not get_settings().openai_api_key:
        return {"transcript": "", "error": "OpenAI API key required.", "note": "offline fallback"}

    try:
        audio_bytes = await _download(file_url)
    except Exception as exc:
        return {"error": f"Could not download the audio: {exc}"}

    filename = resolved_name or params.get("original_filename") or "audio.mp3"
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


# Extracted text is truncated so a huge document can't blow the LLM context
# or the run output payload.
_MAX_EXTRACTED_CHARS = 20000


@tool("extract_document_text")
async def extract_document_text(params: dict[str, Any], ctx: RunContext) -> Any:
    """Extract text content from a document (PDF, Word, Excel, PowerPoint, RTF,
    plain text…) for further processing."""
    file_url, resolved_name = resolve_file_url(
        params,
        mime_prefixes=("application/pdf", "text/", "application/msword", "application/vnd"),
        name_exts=_DOC_EXTS,
    )

    if not file_url:
        return {"error": "No document URL provided."}

    try:
        doc_bytes = await _download(file_url)
    except Exception as exc:
        return {"error": f"Could not download the document: {exc}"}

    filename = resolved_name or params.get("original_filename") or "document"

    result = extractors.extract_bytes(doc_bytes, filename=filename)
    text = result.text if result else ""

    # Last resort: OCR the document with vision (never returns binary).
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
        "format": result.format if result else "ocr",
        "char_count": len(text),
        "truncated": len(text) > _MAX_EXTRACTED_CHARS,
    }
