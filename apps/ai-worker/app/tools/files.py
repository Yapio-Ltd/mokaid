"""File processing tools: image modification, analysis, audio transcription, document extraction.

These tools download attached files from their presigned URLs, process them
using OpenAI APIs + Pillow, and upload the results back to the Phoenix API
as task output files.

Image formats: PNG/JPEG/WebP/GIF/BMP/TIFF via Pillow; SVG as vector (recolor)
or raster via PyMuPDF; exotic formats best-effort via fitz then PNG.
"""

import base64
import io
import re
from typing import Any
from xml.etree import ElementTree as ET

import httpx
import structlog
from PIL import Image, ImageEnhance, ImageFilter, UnidentifiedImageError

from app import llm
from app.memory import extractors
from app.tools.registry import RunContext, tool

log = structlog.get_logger()

_IMAGE_EXTS = (
    ".png",
    ".jpg",
    ".jpeg",
    ".webp",
    ".gif",
    ".bmp",
    ".tiff",
    ".tif",
    ".ico",
    ".svg",
    ".heic",
    ".heif",
    ".avif",
)
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

# Simple recolor intents (logo "colorie en vert") → keep SVG vector when possible.
_RECOLOR_RE = re.compile(
    r"\b("
    r"colori[ee]?[rz]?|recolor(?:e[rz]?)?|teinte[rz]?|"
    r"vert|green|bleu|blue|rouge|red|orange|jaune|yellow|violet|purple|"
    r"rose|pink|noir|black|blanc|white|gris|gray|grey|"
    r"couleur|color|fill|recolorie"
    r")\b",
    re.IGNORECASE,
)

_COLOR_NAME_TO_HEX: dict[str, str] = {
    "vert": "#22c55e",
    "green": "#22c55e",
    "bleu": "#3b82f6",
    "blue": "#3b82f6",
    "rouge": "#ef4444",
    "red": "#ef4444",
    "orange": "#f97316",
    "jaune": "#eab308",
    "yellow": "#eab308",
    "violet": "#8b5cf6",
    "purple": "#8b5cf6",
    "rose": "#ec4899",
    "pink": "#ec4899",
    "noir": "#111827",
    "black": "#111827",
    "blanc": "#ffffff",
    "white": "#ffffff",
    "gris": "#6b7280",
    "gray": "#6b7280",
    "grey": "#6b7280",
}

_HEX_RE = re.compile(r"#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})\b")
_RGB_FUNC_RE = re.compile(
    r"rgb\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*\)", re.IGNORECASE
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


def _is_svg(
    data: bytes | None = None,
    filename: str | None = None,
    mime: str | None = None,
) -> bool:
    """True when the payload (or filename/mime) is SVG."""
    mime_l = (mime or "").lower()
    if "svg" in mime_l:
        return True
    if filename and filename.lower().endswith(".svg"):
        return True
    if not data:
        return False
    head = data[:512].lstrip().lower()
    if head.startswith(b"<svg"):
        return True
    return head.startswith(b"<?xml") and b"<svg" in head


def _rasterize_with_fitz(
    data: bytes,
    *,
    filetype: str | None = None,
    dpi: int = 192,
) -> bytes | None:
    """Rasterize SVG/PDF/etc to PNG via PyMuPDF. Returns PNG bytes or None."""
    try:
        import fitz
    except Exception as exc:  # noqa: BLE001
        log.warning("fitz_unavailable", error=str(exc))
        return None

    try:
        open_kw: dict[str, Any] = {"stream": data}
        if filetype:
            open_kw["filetype"] = filetype
        doc = fitz.open(**open_kw)
        if doc.page_count < 1:
            doc.close()
            return None
        page = doc[0]
        rect = page.rect
        scale = max(dpi / 72.0, 1.0)
        if max(rect.width, rect.height) * scale > 2048:
            scale = 2048 / max(rect.width, rect.height)
        mat = fitz.Matrix(scale, scale)
        pix = page.get_pixmap(matrix=mat, alpha=True)
        png = pix.tobytes("png")
        doc.close()
        return png
    except Exception as exc:  # noqa: BLE001
        log.warning("fitz_rasterize_failed", filetype=filetype, error=str(exc))
        return None


def _prepare_image_bytes(
    data: bytes,
    *,
    filename: str | None = None,
    mime: str | None = None,
) -> tuple[bytes | None, Image.Image | None, str, str | None]:
    """Normalize any supported image into Pillow-ready raster when needed.

    Returns (working_bytes, pillow_image_or_None, format_label, error_message).
    For SVG before rasterization, pillow_image is None and format is "SVG".
    """
    if not data:
        return None, None, "UNKNOWN", "Empty image file."

    if _is_svg(data, filename, mime):
        return data, None, "SVG", None

    try:
        img = Image.open(io.BytesIO(data))
        img.load()
        fmt = (img.format or "PNG").upper()
        return data, img, fmt, None
    except (UnidentifiedImageError, OSError, ValueError) as exc:
        log.info("pillow_open_failed_trying_fitz", error=str(exc), filename=filename)

    guessed = None
    if filename and "." in filename:
        guessed = filename.rsplit(".", 1)[-1].lower() or None
    png = _rasterize_with_fitz(data, filetype=guessed) or _rasterize_with_fitz(data)
    if png:
        try:
            img = Image.open(io.BytesIO(png))
            img.load()
            return png, img, "PNG", None
        except Exception as exc:  # noqa: BLE001
            log.warning("prepared_png_unreadable", error=str(exc))

    return (
        None,
        None,
        "UNKNOWN",
        "Could not read this image format. Try PNG, JPEG, WebP, GIF, or SVG.",
    )


def _looks_like_recolor(instruction: str) -> bool:
    return bool(instruction and _RECOLOR_RE.search(instruction))


def _target_color_hex(instruction: str) -> str | None:
    """Map a plain-language recolor ask to a hex color."""
    if not instruction:
        return None
    hex_match = _HEX_RE.search(instruction)
    if hex_match:
        raw = hex_match.group(0)
        if len(raw) == 4:  # #rgb → #rrggbb
            return "#" + "".join(c * 2 for c in raw[1:]).lower()
        return raw.lower()

    lower = instruction.lower()
    ordered = sorted(_COLOR_NAME_TO_HEX.keys(), key=len, reverse=True)
    for name in ordered:
        if re.search(rf"\b{re.escape(name)}\b", lower):
            return _COLOR_NAME_TO_HEX[name]
    return None


def _hex_to_rgb(hex_color: str) -> tuple[int, int, int] | None:
    h = hex_color.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    if len(h) != 6:
        return None
    try:
        return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    except ValueError:
        return None


def _svg_recolor(svg_bytes: bytes, target_hex: str) -> tuple[bytes | None, str | None]:
    """Replace fill/stroke colors in an SVG with target_hex. Keeps the vector file."""
    try:
        text = svg_bytes.decode("utf-8")
    except UnicodeDecodeError:
        try:
            text = svg_bytes.decode("latin-1")
        except Exception:
            return None, "SVG encoding could not be decoded."

    if "<svg" not in text.lower():
        return None, "File is not a valid SVG."

    target = target_hex if target_hex.startswith("#") else f"#{target_hex}"
    target_rgb = _hex_to_rgb(target)
    if not target_rgb:
        return None, f"Invalid target color: {target_hex}"

    target_rgb_str = f"rgb({target_rgb[0]},{target_rgb[1]},{target_rgb[2]})"

    def repl_hex(_match: re.Match[str]) -> str:
        return target

    colored = _HEX_RE.sub(repl_hex, text)
    colored = _RGB_FUNC_RE.sub(target_rgb_str, colored)

    # Explicit fill/stroke attributes that use named colors or currentColor.
    colored = re.sub(
        r'\b(fill|stroke)\s*=\s*([\'"])(?!none|transparent|url\()[^\'"]+\2',
        rf"\1=\2{target}\2",
        colored,
        flags=re.IGNORECASE,
    )
    # Inline style fill:… / stroke:…
    colored = re.sub(
        r"(fill|stroke)\s*:\s*(?!none|transparent|url\()[^;}\"']+",
        rf"\1: {target}",
        colored,
        flags=re.IGNORECASE,
    )

    if colored == text:
        # No color attributes found — force fill on shapes.
        colored = re.sub(
            r"<(path|rect|circle|ellipse|polygon|polyline|line)\b",
            rf'<\1 fill="{target}"',
            text,
            flags=re.IGNORECASE,
        )

    if colored == text:
        return None, "Could not apply color to this SVG."

    try:
        ET.fromstring(colored)
    except ET.ParseError:
        # Accept imperfect SVGs if colors did change (namespaces, entities…).
        pass

    return colored.encode("utf-8"), None


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
        mime = f.get("mime_type") or ""
        # SVG often arrives as image/svg+xml — or application/svg+xml.
        if "svg" in mime.lower() and (
            any(p.startswith("image") for p in mime_prefixes) or ".svg" in name_exts
        ):
            return True
        return _mime_matches(mime, mime_prefixes) or _name_matches(
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


async def _save_image_output(
    ctx: RunContext,
    *,
    result_bytes: bytes,
    filename: str,
    mime: str,
    description: str,
    method: str,
    source_filename: str | None,
) -> dict[str, Any]:
    if not ctx.phoenix:
        return {
            "filename": filename,
            "description": description,
            "size_bytes": len(result_bytes),
            "method": method,
            "source_filename": source_filename,
            "note": "no phoenix — not uploaded",
        }

    if mime == "image/svg+xml":
        try:
            body = result_bytes.decode("utf-8")
            encoding: str | None = None
        except UnicodeDecodeError:
            body = base64.b64encode(result_bytes).decode()
            encoding = "base64"
    else:
        body = base64.b64encode(result_bytes).decode()
        encoding = "base64"

    saved = await ctx.phoenix.save_task_output(
        ctx.workspace_id,
        ctx.task_id,
        filename,
        body,
        mime_type=mime,
        encoding=encoding,
    )
    if saved:
        return {
            "filename": filename,
            "description": description,
            "size_bytes": len(result_bytes),
            "method": method,
            "source_filename": source_filename,
        }
    return {"error": "Could not save the processed image.", "method": method}


@tool("analyze_file")
async def analyze_file(params: dict[str, Any], ctx: RunContext) -> Any:
    """Analyze any file (image, document) using GPT-4 Vision and return a text description."""
    question = params.get("question") or ctx.task_description or "Describe this file in detail."
    file_url, resolved_name = resolve_file_url(params)

    if not file_url:
        return {"analysis": "", "error": "No file URL provided. Ensure a file is attached to the task."}

    from app.config import get_settings

    if not get_settings().openai_api_key:
        return {
            "analysis": "",
            "error": "OpenAI API key required for vision analysis.",
            "note": "offline fallback",
        }

    # Download first so Vision gets a data URL — OpenAI cannot reach localhost MinIO.
    try:
        image_bytes = await _download(file_url)
    except Exception as exc:
        return {"analysis": "", "error": f"Could not download the file: {exc}"}

    mime = params.get("mime_type") or ""
    filename = resolved_name or params.get("original_filename") or ""

    # Vision models need raster pixels — rasterize SVG / unreadable formats.
    if _is_svg(image_bytes, filename, mime):
        png = _rasterize_with_fitz(image_bytes, filetype="svg")
        if not png:
            return {
                "analysis": "",
                "error": "Could not rasterize this SVG for analysis. Try exporting as PNG.",
            }
        image_bytes = png
        mime = "image/png"
    else:
        prepared, _img, _fmt, _prep_err = _prepare_image_bytes(
            image_bytes, filename=filename, mime=mime
        )
        if prepared and prepared is not image_bytes:
            image_bytes = prepared
            mime = "image/png"

    analysis = await llm.vision(
        system="You are a helpful assistant. Analyze the provided file/image and answer the user's question thoroughly. Reply in the same language as the question.",
        user_text=question,
        image_url=file_url,
        image_bytes=image_bytes,
        mime_type=mime or None,
        usage=ctx.usage,
        max_tokens=1500,
    )
    return {"analysis": analysis, "file_url": file_url}


@tool("transform_image")
async def transform_image(params: dict[str, Any], ctx: RunContext) -> Any:
    """Transform/modify an image based on instructions. Supports color changes, filters,
    adjustments, format conversion, SVG recolor, and creative modifications via AI."""
    instruction = params.get("instruction") or ctx.task_description or ""
    file_url, resolved_name = resolve_file_url(
        params, mime_prefixes=("image/",), name_exts=_IMAGE_EXTS
    )
    if resolved_name and not params.get("original_filename"):
        params = {**params, "original_filename": resolved_name}

    # Image edit/generate stays on OpenAI (DALL·E / gpt-image) — DeepSeek and
    # Anthropic do not provide an images API. Check the OpenAI key specifically
    # rather than llm.is_configured(), which is true when only text providers
    # are set.
    from app.config import get_settings

    has_key = bool(get_settings().openai_api_key)

    if not file_url:
        # No source image attached. A creation-style ask ("create a logo…")
        # can still be honored via text-to-image; a modification ask cannot —
        # surface an actionable error the runner turns into a user question.
        if _looks_like_creation(instruction):
            if not has_key:
                return {
                    "error": "OpenAI API key required for image processing.",
                    "note": "offline fallback",
                }
            return await _generate_from_scratch(instruction, params, ctx)
        return {
            "error": (
                "No image is attached to this task. Attach the image to modify "
                "(drop it on the task or in chat), then retry."
            ),
            "needs_user_input": True,
        }

    filename = params.get("original_filename") or resolved_name or "image"
    mime_hint = params.get("mime_type") or ""
    source_name = filename
    looks_svgish = _is_svg(None, filename, mime_hint) or (file_url or "").lower().endswith(
        ".svg"
    )

    # Without an OpenAI key, only offline-capable SVG recolor is possible.
    # Avoid network for PNG/JPEG etc. so offline tests and air-gapped runs
    # fail fast with a clear note.
    if not has_key:
        if looks_svgish and _looks_like_recolor(instruction):
            try:
                raw_bytes = await _download(file_url)
            except Exception as exc:
                return {"error": f"Could not download the image: {exc}"}
            target = _target_color_hex(instruction)
            if target and _is_svg(raw_bytes, filename, mime_hint):
                recolored, _err = _svg_recolor(raw_bytes, target)
                if recolored:
                    clean_name = re.sub(r"\.[^.]+$", "", filename) or "logo"
                    out_name = f"{clean_name}-modified.svg"
                    return await _save_image_output(
                        ctx,
                        result_bytes=recolored,
                        filename=out_name,
                        mime="image/svg+xml",
                        description=f"Recolored the SVG to {target}: {instruction[:120]}",
                        method="svg_recolor",
                        source_filename=source_name,
                    )
        return {
            "error": "OpenAI API key required for image processing.",
            "note": "offline fallback",
        }

    try:
        raw_bytes = await _download(file_url)
    except Exception as exc:
        return {"error": f"Could not download the image: {exc}"}

    # --- SVG: recolor vector path (crisp logos) ---
    if _is_svg(raw_bytes, filename, mime_hint) and _looks_like_recolor(instruction):
        target = _target_color_hex(instruction)
        if target:
            recolored, recolor_err = _svg_recolor(raw_bytes, target)
            if recolored:
                clean_name = re.sub(r"\.[^.]+$", "", filename) or "logo"
                out_name = f"{clean_name}-modified.svg"
                return await _save_image_output(
                    ctx,
                    result_bytes=recolored,
                    filename=out_name,
                    mime="image/svg+xml",
                    description=f"Recolored the SVG to {target}: {instruction[:120]}",
                    method="svg_recolor",
                    source_filename=source_name,
                )
            log.warning("svg_recolor_failed", error=recolor_err, run_id=ctx.run_id)

    prepared, img, original_format, prep_err = _prepare_image_bytes(
        raw_bytes, filename=filename, mime=mime_hint
    )

    # SVG creative edits (or failed recolor) → rasterize then AI/Pillow path.
    if original_format == "SVG":
        png = _rasterize_with_fitz(prepared or raw_bytes, filetype="svg")
        if not png:
            png = _rasterize_with_fitz(raw_bytes)
        if not png:
            return {
                "error": (
                    "Could not process this SVG. Try a simple recolor "
                    "(e.g. 'color it green') or export the logo as PNG."
                )
            }
        prepared = png
        try:
            img = Image.open(io.BytesIO(png))
            img.load()
        except Exception:
            return {"error": "SVG rasterization produced an unreadable image."}
        original_format = "PNG"
    elif prep_err or img is None or prepared is None:
        return {
            "error": prep_err
            or "Could not read this image format. Try PNG, JPEG, WebP, GIF, or SVG."
        }

    image_bytes = prepared

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
        result_bytes, edit_error = await llm.edit_image(
            image_bytes, edit_prompt, usage=ctx.usage, mime_type=source_mime
        )
        if result_bytes:
            output_format = "PNG"  # gpt-image-1 returns PNG
            description = f"AI-edited the image: {edit_prompt[:150]}"
        else:
            # Editing unavailable (model access, size limits…) — regenerate
            # from a vision description so the request still lands, which
            # beats degrading to a color filter.
            log.warning(
                "ai_edit_unavailable_falling_back", run_id=ctx.run_id, error=edit_error
            )
            fallback_prompt = (
                f"Recreate this exact image with the following change applied: {edit_prompt}"
            )
            result_bytes, gen_error = await llm.generate_image(
                fallback_prompt, usage=ctx.usage
            )
            if result_bytes:
                output_format = "PNG"
                description = (
                    f"Regenerated the image with the requested change: {edit_prompt[:120]}"
                )
            else:
                return {
                    "error": "AI image editing failed. Try rephrasing the instruction or retry later.",
                    "provider_error": gen_error or edit_error,
                    "method": "ai_edit",
                    "edit_prompt": edit_prompt[:300],
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
        result_bytes, gen_error = await llm.generate_image(dalle_prompt, usage=ctx.usage)
        if result_bytes:
            description = f"Generated new image: {dalle_prompt[:100]}"
        else:
            return {
                "error": "Image generation failed. Try rephrasing the instruction.",
                "provider_error": gen_error,
                "method": "dalle",
            }

    if result_bytes is None:
        return {"error": "Image processing produced no output."}

    ext = output_format.lower()
    mime = f"image/{ext}"
    original_name = params.get("original_filename") or "image"
    clean_name = re.sub(r"\.[^.]+$", "", original_name)
    out_filename = f"{clean_name}-modified.{ext}"

    return await _save_image_output(
        ctx,
        result_bytes=result_bytes,
        filename=out_filename,
        mime=mime,
        description=description,
        method=method,
        source_filename=source_name,
    )


_CREATION_RE = re.compile(
    r"\b("
    r"cr[ée]{1,2}[erz]?|con[çc]ois|conception|dessine|g[ée]n[èe]re[rz]?|imagine|invente|"
    r"create|design|draw|generate|make|invent"
    r")\b",
    re.IGNORECASE,
)


def _looks_like_creation(instruction: str) -> bool:
    """True when the ask is to CREATE an image from scratch (vs modify one)."""
    return bool(instruction and _CREATION_RE.search(instruction))


async def _generate_from_scratch(
    instruction: str, params: dict[str, Any], ctx: RunContext
) -> dict[str, Any]:
    """Text-to-image path for creation asks that arrive without a source file."""
    result_bytes, gen_error = await llm.generate_image(instruction, usage=ctx.usage)
    if not result_bytes:
        return {
            "error": "Image generation failed. Try rephrasing the instruction.",
            "provider_error": gen_error,
            "method": "generate",
        }

    original_name = params.get("original_filename") or "image"
    clean_name = re.sub(r"\.[^.]+$", "", original_name)
    filename = f"{clean_name}-generated.png"
    return await _save_image_output(
        ctx,
        result_bytes=result_bytes,
        filename=filename,
        mime="image/png",
        description=f"Generated a new image from the brief: {instruction[:150]}",
        method="generate",
        source_filename=params.get("original_filename"),
    )


@tool("export_pdf")
async def export_pdf(params: dict[str, Any], ctx: RunContext) -> Any:
    """Render markdown/text content as a styled PDF and save it as a task
    deliverable. This is the default packaging for documents and analyses."""
    from app import pdf as pdf_mod

    content = params.get("content") or ""
    title = params.get("title") or ctx.task_title or "Document"
    if not content.strip():
        return {"error": "No content provided to export."}

    try:
        pdf_bytes = pdf_mod.markdown_to_pdf_bytes(content, title=title)
    except Exception as exc:  # noqa: BLE001 — surface, don't crash the run
        log.warning("pdf_export_failed", run_id=ctx.run_id, error=str(exc))
        return {"error": f"PDF rendering failed: {exc}"}

    filename = params.get("filename") or f"{_safe_pdf_name(title)}.pdf"
    if not filename.lower().endswith(".pdf"):
        filename += ".pdf"

    if ctx.phoenix:
        saved = await ctx.phoenix.save_task_output(
            ctx.workspace_id,
            ctx.task_id,
            filename,
            base64.b64encode(pdf_bytes).decode(),
            mime_type="application/pdf",
            encoding="base64",
        )
        if saved:
            return {
                "filename": filename,
                "size_bytes": len(pdf_bytes),
                "description": f"Exported '{title}' as PDF.",
            }
    return {"error": "Could not save the PDF."}


def _safe_pdf_name(title: str) -> str:
    clean = re.sub(r"[^\w\s-]", "", title).strip().replace(" ", "-")[:60]
    return clean or "document"


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
