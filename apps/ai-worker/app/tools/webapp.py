"""Full React + Next.js + TypeScript codebase for complex site missions.

Pipeline:
1. Art direction + premium HTML preview (via `generate_website`).
2. Multi-file Next App Router project (LLM JSON or solid fallback).
3. Persist key files + a GitHub-friendly ZIP + CODEBASE.md.
"""

from __future__ import annotations

import base64
import io
import json
import zipfile
from typing import Any

import structlog

from app import llm
from app.tools.registry import RunContext, tool
from app.tools.website import _slugify, generate_website

log = structlog.get_logger()

_CODEBASE_SYSTEM = """You generate a production-ready Next.js App Router
(TypeScript) project as a JSON object. Keys are relative file paths, values
are full file contents (strings).

Required files (always include all of these):
- package.json (next 15, react 19, typescript)
- tsconfig.json
- next.config.ts
- next-env.d.ts
- app/layout.tsx
- app/page.tsx
- app/globals.css
- README.md
- CODEBASE.md  (short map of the repo for humans)

Also include 2–5 pages/components matching the brief. For ecommerce/shop:
- app/catalogue/page.tsx (or app/shop/page.tsx)
- app/produit/[slug]/page.tsx or app/product/[slug]/page.tsx
- app/contact/page.tsx
- components/Header.tsx, ProductCard.tsx, CartDrawer.tsx (UI only, no real payments)

Design rules (match the provided design system):
- Expressive Google Fonts (never Inter/Roboto/Arial)
- Full-bleed hero on the home page, one CTA group, no clutter
- No purple-on-white AI cliché, no cream+terracotta broadsheet look
- WCAG AA contrast; 2–3 subtle motions max
- Real product copy in the brief's language — no lorem ipsum

Return ONLY a JSON object: {"files": {"path": "content", ...}}.
No markdown fences, no commentary."""


def _package_json(slug: str) -> dict[str, Any]:
    return {
        "name": slug,
        "version": "0.1.0",
        "private": True,
        "scripts": {
            "dev": "next dev",
            "build": "next build",
            "start": "next start",
            "lint": "next lint",
        },
        "dependencies": {
            "next": "^15.1.0",
            "react": "^19.0.0",
            "react-dom": "^19.0.0",
        },
        "devDependencies": {
            "@types/node": "^22.10.0",
            "@types/react": "^19.0.0",
            "@types/react-dom": "^19.0.0",
            "typescript": "^5.7.0",
        },
    }


_TSCONFIG = {
    "compilerOptions": {
        "target": "ES2017",
        "lib": ["dom", "dom.iterable", "esnext"],
        "allowJs": True,
        "skipLibCheck": True,
        "strict": True,
        "noEmit": True,
        "esModuleInterop": True,
        "module": "esnext",
        "moduleResolution": "bundler",
        "resolveJsonModule": True,
        "isolatedModules": True,
        "jsx": "preserve",
        "incremental": True,
        "plugins": [{"name": "next"}],
        "paths": {"@/*": ["./*"]},
    },
    "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts"],
    "exclude": ["node_modules"],
}


def _escape_js(s: str) -> str:
    return (s or "").replace("\\", "\\\\").replace("`", "\\`").replace("${", "\\${")


def _fallback_files(brand: str, brief: str, design: dict[str, Any] | None) -> dict[str, str]:
    """Solid multi-page Next scaffold when the LLM file pass is unavailable."""
    slug_brand = brand or "Boutique"
    palette = (design or {}).get("palette") or {}
    fonts = (design or {}).get("fonts") or {}
    primary = palette.get("primary") or "#1a3a2a"
    bg = palette.get("background") or "#f7f3ec"
    text = palette.get("text") or "#141814"
    cta = palette.get("cta") or primary
    heading = fonts.get("heading") or "Fraunces"
    body = fonts.get("body") or "Source Serif 4"

    globals_css = f""":root {{
  --bg: {bg};
  --text: {text};
  --primary: {primary};
  --cta: {cta};
  --muted: color-mix(in srgb, {text} 55%, transparent);
}}
* {{ box-sizing: border-box; }}
html, body {{ margin: 0; padding: 0; background: var(--bg); color: var(--text);
  font-family: "{body}", Georgia, serif; }}
h1, h2, h3 {{ font-family: "{heading}", Georgia, serif; font-weight: 550; letter-spacing: -0.02em; }}
a {{ color: inherit; text-decoration: none; }}
.btn {{ display: inline-flex; align-items: center; justify-content: center;
  background: var(--cta); color: #fff; padding: 0.85rem 1.4rem; border: 0;
  border-radius: 0.35rem; font: inherit; cursor: pointer; transition: transform .2s, opacity .2s; }}
.btn:hover {{ transform: translateY(-1px); opacity: 0.92; }}
.hero {{ min-height: 92vh; display: grid; align-content: end; padding: 2rem clamp(1.25rem, 4vw, 4rem) 4rem;
  background: linear-gradient(160deg, color-mix(in srgb, var(--primary) 18%, var(--bg)), var(--bg)); }}
.hero h1 {{ font-size: clamp(2.4rem, 7vw, 4.6rem); line-height: 1.05; max-width: 14ch; margin: 0 0 1rem; }}
.hero p {{ max-width: 36rem; font-size: 1.1rem; line-height: 1.55; color: var(--muted); }}
.grid {{ display: grid; gap: 1.25rem; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
  padding: 3rem clamp(1.25rem, 4vw, 4rem); }}
.card {{ border-top: 1px solid color-mix(in srgb, var(--text) 12%, transparent); padding-top: 1rem; }}
.card h3 {{ margin: 0 0 0.35rem; font-size: 1.15rem; }}
.nav {{ display: flex; gap: 1.25rem; padding: 1rem clamp(1.25rem, 4vw, 4rem); align-items: center; }}
.nav strong {{ margin-right: auto; font-family: "{heading}", Georgia, serif; }}
@media (prefers-reduced-motion: reduce) {{ * {{ transition: none !important; }} }}
"""

    layout = f'''import type {{ Metadata }} from "next";
import "./globals.css";
import {{ Header }} from "@/components/Header";

export const metadata: Metadata = {{
  title: "{_escape_js(slug_brand)}",
  description: "Generated with MOKAID — React + Next.js + TypeScript",
}};

export default function RootLayout({{ children }}: {{ children: React.ReactNode }}) {{
  return (
    <html lang="fr">
      <head>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link
          href="https://fonts.googleapis.com/css2?family={heading.replace(' ', '+')}:wght@400;550;700&family={body.replace(' ', '+')}:wght@400;600&display=swap"
          rel="stylesheet"
        />
      </head>
      <body>
        <Header brand="{_escape_js(slug_brand)}" />
        {{children}}
      </body>
    </html>
  );
}}
'''

    header = '''export function Header({ brand }: { brand: string }) {
  return (
    <nav className="nav">
      <strong>{brand}</strong>
      <a href="/">Accueil</a>
      <a href="/catalogue">Catalogue</a>
      <a href="/contact">Contact</a>
    </nav>
  );
}
'''

    product_card = '''export type Product = { slug: string; name: string; price: string; blurb: string };

export function ProductCard({ product }: { product: Product }) {
  return (
    <article className="card">
      <h3>{product.name}</h3>
      <p style={{ color: "var(--muted)", margin: "0 0 0.75rem", lineHeight: 1.45 }}>{product.blurb}</p>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <span>{product.price}</span>
        <a className="btn" href={`/produit/${product.slug}`}>Voir</a>
      </div>
    </article>
  );
}
'''

    products_ts = '''export const products = [
  { slug: "table-chene", name: "Table chêne massif", price: "1 890 €", blurb: "Plateau huilé, pieds sculptés à la main." },
  { slug: "table-noyer", name: "Table noyer", price: "2 240 €", blurb: "Lignes sobres, finition mate naturelle." },
  { slug: "console-frene", name: "Console frêne", price: "980 €", blurb: "Pièce d’entrée, grain ouvert." },
  { slug: "banc-orme", name: "Banc orme", price: "720 €", blurb: "Assise généreuse pour la table longue." },
];
'''

    page = f'''import {{ products }} from "@/lib/products";
import {{ ProductCard }} from "@/components/ProductCard";

export default function Home() {{
  return (
    <main>
      <section className="hero">
        <p style={{{{ letterSpacing: "0.12em", textTransform: "uppercase", fontSize: 12, color: "var(--muted)" }}}}>
          {_escape_js(slug_brand)}
        </p>
        <h1>Des tables qui portent la maison</h1>
        <p>Pièces uniques en bois noble — conçues pour durer, livrées chez vous.</p>
        <p style={{{{ marginTop: "1.5rem" }}}}>
          <a className="btn" href="/catalogue">Explorer le catalogue</a>
        </p>
      </section>
      <section className="grid">
        {{products.slice(0, 3).map((p) => (
          <ProductCard key={{p.slug}} product={{p}} />
        ))}}
      </section>
    </main>
  );
}}
'''

    catalogue = '''import { products } from "@/lib/products";
import { ProductCard } from "@/components/ProductCard";

export default function CataloguePage() {
  return (
    <main style={{ paddingBottom: "4rem" }}>
      <header style={{ padding: "3rem clamp(1.25rem, 4vw, 4rem) 0" }}>
        <h1 style={{ fontSize: "clamp(2rem, 5vw, 3rem)", margin: 0 }}>Catalogue</h1>
        <p style={{ color: "var(--muted)", maxWidth: 420 }}>
          Chaque pièce est fabriquée sur commande. Choisissez, puis contactez-nous.
        </p>
      </header>
      <section className="grid">
        {products.map((p) => (
          <ProductCard key={p.slug} product={p} />
        ))}
      </section>
    </main>
  );
}
'''

    product_page = '''import { products } from "@/lib/products";
import { notFound } from "next/navigation";

export default async function ProductPage({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;
  const product = products.find((p) => p.slug === slug);
  if (!product) notFound();
  return (
    <main style={{ padding: "3rem clamp(1.25rem, 4vw, 4rem)", maxWidth: 720 }}>
      <p style={{ color: "var(--muted)", letterSpacing: "0.08em", textTransform: "uppercase", fontSize: 12 }}>
        Fiche produit
      </p>
      <h1 style={{ fontSize: "clamp(2rem, 5vw, 3.2rem)", margin: "0.4rem 0 1rem" }}>{product.name}</h1>
      <p style={{ fontSize: "1.25rem" }}>{product.price}</p>
      <p style={{ color: "var(--muted)", lineHeight: 1.6 }}>{product.blurb}</p>
      <p style={{ marginTop: "2rem" }}>
        <a className="btn" href="/contact">Demander un devis</a>
      </p>
    </main>
  );
}
'''

    contact = f'''export default function ContactPage() {{
  return (
    <main style={{{{ padding: "3rem clamp(1.25rem, 4vw, 4rem)", maxWidth: 560 }}}}>
      <h1>Contact</h1>
      <p style={{{{ color: "var(--muted)", lineHeight: 1.55 }}}}>
        Une question sur {_escape_js(slug_brand)} ? Écrivez-nous — réponse sous 24h.
      </p>
      <form style={{{{ display: "grid", gap: "0.75rem", marginTop: "1.5rem" }}}}>
        <input name="name" placeholder="Nom" style={{{{ padding: "0.75rem", borderRadius: 6, border: "1px solid #ccc" }}}} />
        <input name="email" type="email" placeholder="Email" style={{{{ padding: "0.75rem", borderRadius: 6, border: "1px solid #ccc" }}}} />
        <textarea name="message" rows={{4}} placeholder="Message" style={{{{ padding: "0.75rem", borderRadius: 6, border: "1px solid #ccc" }}}} />
        <button className="btn" type="button">Envoyer</button>
      </form>
    </main>
  );
}}
'''

    cart = '''"use client";

import { useState } from "react";

/** UI-only cart drawer — wire to real checkout later. */
export function CartDrawer() {
  const [open, setOpen] = useState(false);
  return (
    <>
      <button type="button" className="btn" onClick={() => setOpen(true)} style={{ position: "fixed", right: 16, bottom: 16 }}>
        Panier
      </button>
      {open && (
        <aside
          style={{
            position: "fixed", inset: "auto 0 0 auto", width: 320, maxWidth: "100%",
            background: "var(--bg)", borderLeft: "1px solid color-mix(in srgb, var(--text) 12%, transparent)",
            padding: "1.25rem", minHeight: "40vh", boxShadow: "-8px 0 24px rgba(0,0,0,.08)",
          }}
        >
          <h2 style={{ marginTop: 0 }}>Votre panier</h2>
          <p style={{ color: "var(--muted)" }}>Ajoutez des pièces depuis le catalogue.</p>
          <button type="button" className="btn" onClick={() => setOpen(false)}>Fermer</button>
        </aside>
      )}
    </>
  );
}
'''

    readme = f"""# {_escape_js(slug_brand)}

Generated by MOKAID — React + Next.js (App Router) + TypeScript.

## Preview in MOKAID
Open the HTML deliverable for an immersive design preview (no install).

## Local
```bash
npm install
npm run dev
```

## Deploy
1. Create a GitHub repo: https://github.com/new — upload this folder or the ZIP.
2. Import on [Vercel](https://vercel.com/new) or [Render](https://dashboard.render.com/).
3. Optional backend: [Supabase](https://supabase.com/dashboard/new).

## Brief
{brief[:1200]}
"""

    codebase_md = f"""# Codebase map — {_escape_js(slug_brand)}

| Path | Role |
|------|------|
| `app/page.tsx` | Home + hero |
| `app/catalogue/page.tsx` | Product grid |
| `app/produit/[slug]/page.tsx` | Product detail |
| `app/contact/page.tsx` | Contact form (UI) |
| `components/` | Header, ProductCard, CartDrawer |
| `lib/products.ts` | Sample catalogue data |
| `app/globals.css` | Design tokens aligned with HTML preview |

Stack: React 19 · Next.js 15 · TypeScript.
This is a **full source codebase**, not only the HTML preview.
"""

    files: dict[str, str] = {
        "package.json": json.dumps(_package_json(_slugify(slug_brand)), indent=2) + "\n",
        "tsconfig.json": json.dumps(_TSCONFIG, indent=2) + "\n",
        "next.config.ts": "import type { NextConfig } from 'next';\n\nconst nextConfig: NextConfig = {};\nexport default nextConfig;\n",
        "next-env.d.ts": '/// <reference types="next" />\n/// <reference types="next/image-types/global" />\n',
        "vercel.json": json.dumps({"$schema": "https://openapi.vercel.sh/vercel.json", "framework": "nextjs"}, indent=2)
        + "\n",
        ".env.example": "NEXT_PUBLIC_SUPABASE_URL=\nNEXT_PUBLIC_SUPABASE_ANON_KEY=\n",
        "app/globals.css": globals_css,
        "app/layout.tsx": layout,
        "app/page.tsx": page,
        "components/Header.tsx": header,
        "components/ProductCard.tsx": product_card,
        "components/CartDrawer.tsx": cart,
        "lib/products.ts": products_ts,
        "app/catalogue/page.tsx": catalogue,
        "app/produit/[slug]/page.tsx": product_page,
        "app/contact/page.tsx": contact,
        "README.md": readme,
        "CODEBASE.md": codebase_md,
    }
    return files


async def _llm_files(
    brief: str, brand: str, design: dict[str, Any] | None, ctx: RunContext
) -> dict[str, str] | None:
    if not llm.is_configured():
        return None
    try:
        raw = await llm.chat_json(
            system=_CODEBASE_SYSTEM,
            user=(
                f"Brief:\n{brief}\n\nBrand: {brand}\n\n"
                f"Design system (match colors/fonts/mood):\n{json.dumps(design or {}, ensure_ascii=False)}\n"
            ),
            usage=ctx.usage,
            max_tokens=12000,
            quality="smart",
        )
    except Exception as exc:  # noqa: BLE001
        log.warning("webapp_llm_files_failed", error=str(exc))
        return None

    files = raw.get("files") if isinstance(raw, dict) else None
    if not isinstance(files, dict) or not files:
        # Some models return flat path→content
        if isinstance(raw, dict) and any("/" in str(k) or k.endswith(".tsx") for k in raw):
            files = {k: v for k, v in raw.items() if isinstance(v, str) and k != "error"}
        else:
            return None

    cleaned: dict[str, str] = {}
    for path, content in files.items():
        if not isinstance(path, str) or not isinstance(content, str):
            continue
        p = path.lstrip("./").replace("\\", "/")
        if ".." in p or p.startswith("/"):
            continue
        cleaned[p] = content
    return cleaned or None


def _merge_scaffold(llm_files: dict[str, str] | None, fallback: dict[str, str]) -> dict[str, str]:
    out = dict(fallback)
    if llm_files:
        out.update(llm_files)
    # Guarantee essentials
    for key in ("package.json", "app/page.tsx", "app/layout.tsx", "README.md", "CODEBASE.md"):
        if key not in out:
            out[key] = fallback.get(key, "")
    return {k: v for k, v in out.items() if v}


def _zip_bytes(files: dict[str, str], root: str) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for path, content in sorted(files.items()):
            zf.writestr(f"{root}/{path}", content)
    return buf.getvalue()


@tool("generate_webapp")
async def generate_webapp(params: dict[str, Any], ctx: RunContext) -> Any:
    """Builds a real React/Next.js/TypeScript multi-file codebase plus HTML
    preview, ZIP download, and GitHub/Vercel docs."""
    brief = (
        params.get("brief")
        or params.get("instructions")
        or ctx.task_description
        or ctx.task_title
        or ""
    )
    brand = params.get("brand_name") or params.get("brand") or "App"
    style = params.get("style") or ""

    if not brief:
        return {"error": "No brief provided for the webapp."}

    enriched = (
        f"{brief}\n\n"
        "Also produce a premium immersive HTML preview of the same brand: "
        "full-bleed hero, expressive typography, real ecommerce content when relevant "
        "(product grid, product page cues, CTA), no AI design clichés."
    )

    site = await generate_website(
        {"brief": enriched, "brand_name": brand, "style": style},
        ctx,
    )
    if isinstance(site, dict) and site.get("error"):
        return site

    design = {
        "style": site.get("style") if isinstance(site, dict) else None,
        "pattern": site.get("pattern") if isinstance(site, dict) else None,
        "mood": site.get("mood") if isinstance(site, dict) else None,
        "sections": site.get("sections") if isinstance(site, dict) else None,
    }

    slug = _slugify(brand or ctx.task_title or "webapp")
    fallback = _fallback_files(brand, brief, design)
    llm_part = await _llm_files(brief, brand, design, ctx)
    files = _merge_scaffold(llm_part, fallback)

    artifacts: list[dict[str, Any]] = []
    if isinstance(site, dict) and site.get("filename"):
        artifacts.append(
            {
                "filename": site["filename"],
                "drive_item_id": site.get("drive_item_id"),
                "kind": "preview_html",
            }
        )

    # Persist a curated subset as individual Drive files + full ZIP.
    highlight_paths = [
        "CODEBASE.md",
        "README.md",
        "package.json",
        "app/page.tsx",
        "app/layout.tsx",
        "app/globals.css",
    ]
    if ctx.phoenix:
        for path in highlight_paths:
            body = files.get(path)
            if not body:
                continue
            fname = f"{slug}/{path}" if "/" in path else f"{slug}-{path}"
            if path == "CODEBASE.md":
                fname = f"{slug}-CODEBASE.md"
            elif path == "README.md":
                fname = f"{slug}-README.md"
            elif path == "package.json":
                fname = f"{slug}-package.json"
            elif path.startswith("app/"):
                fname = f"{slug}-{path.replace('/', '-')}"

            mime = (
                "text/markdown"
                if path.endswith(".md")
                else "application/json"
                if path.endswith(".json")
                else "text/css"
                if path.endswith(".css")
                else "text/typescript"
            )
            saved = await ctx.phoenix.save_task_output(
                ctx.workspace_id, ctx.task_id, fname, body, mime_type=mime
            )
            if saved:
                artifacts.append(
                    {
                        "filename": fname,
                        "drive_item_id": saved.get("id") or saved.get("drive_item_id"),
                        "kind": "scaffold",
                        "path": path,
                    }
                )

        zip_name = f"{slug}-codebase.zip"
        zbytes = _zip_bytes(files, slug)
        saved_zip = await ctx.phoenix.save_task_output(
            ctx.workspace_id,
            ctx.task_id,
            zip_name,
            base64.b64encode(zbytes).decode(),
            mime_type="application/zip",
            encoding="base64",
        )
        if saved_zip:
            artifacts.append(
                {
                    "filename": zip_name,
                    "drive_item_id": saved_zip.get("id") or saved_zip.get("drive_item_id"),
                    "kind": "codebase_zip",
                }
            )

    if not artifacts:
        return {"error": "Could not save the webapp codebase."}

    file_tree = sorted(files.keys())
    log.info("webapp_generated", brand=brand, files=len(file_tree), artifacts=len(artifacts))
    return {
        "filename": site.get("filename") if isinstance(site, dict) else None,
        "drive_item_id": site.get("drive_item_id") if isinstance(site, dict) else None,
        "mime_type": "text/html",
        "artifacts": artifacts,
        "file_tree": file_tree,
        "stack": "React + Next.js App Router + TypeScript",
        "commands": ["npm install", "npm run dev", "npm run build"],
        "zip_filename": f"{slug}-codebase.zip",
        "deploy": {
            "github": "https://github.com/new",
            "vercel": "https://vercel.com/new",
            "render": "https://dashboard.render.com/select-repo?type=web",
            "supabase": "https://supabase.com/dashboard/new",
        },
        "note": (
            "Full React/Next/TypeScript codebase generated (ZIP + source files) "
            "plus an HTML live preview. Open the HTML in MOKAID, download the ZIP "
            "for GitHub, then npm install && npm run dev locally."
        ),
    }
