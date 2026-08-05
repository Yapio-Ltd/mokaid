import { useEffect, useState, type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { ArrowRight, Menu, X } from "lucide-react";
import { SiteFooter } from "@/components/landing/site-footer";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/cn";
import { useAuthStore } from "@/stores/auth-store";
import type { BreadcrumbItem, FaqItem } from "@/lib/seo";

const navLinks = [
  { href: "/ai-employees", label: "AI Employees" },
  { href: "/use-cases", label: "Use Cases" },
  { href: "/pricing", label: "Pricing" },
  { href: "/compare", label: "Compare" },
  { href: "/blog", label: "Blog" },
  { href: "/glossary", label: "Glossary" },
] as const;

function MarketingLogo() {
  return (
    <span className="flex items-center gap-2.5">
      <span className="relative flex h-9 w-9 items-center justify-center rounded-xl border border-primary/20 bg-primary/10">
        <picture>
          <source srcSet="/branding/logo-without-bg.webp" type="image/webp" />
          <img
            src="/branding/logo-without-bg.png"
            alt="mokaid"
            className="h-6 w-6 object-contain"
            width={28}
            height={28}
            decoding="async"
          />
        </picture>
      </span>
      <span className="mk-brand-wordmark text-[15px] tracking-tight text-text sm:text-[17px]">
        mokaid
      </span>
    </span>
  );
}

/**
 * Shared shell for the public SEO/content pages. Mirrors the landing page's
 * header design (glass, same logo/nav/CTA styles) but stays always visible,
 * and reuses the landing SiteFooter for a consistent look.
 */
export function MarketingLayout({ children }: { children: ReactNode }) {
  const [menuOpen, setMenuOpen] = useState(false);
  const token = useAuthStore((s) => s.token);

  useEffect(() => {
    // These pages use document scroll like the landing (app shell uses inner scroll).
    document.documentElement.style.overflowY = "auto";
    window.scrollTo(0, 0);
    return () => {
      document.documentElement.style.overflowY = "";
    };
  }, []);

  return (
    <div className="mk-landing min-h-full overflow-x-clip bg-bg-deep text-text">
      <header className="mk-glass sticky top-0 z-50 border-b border-primary/15 pt-[env(safe-area-inset-top)]">
        <div className="mx-auto grid h-14 max-w-7xl grid-cols-[1fr_auto] items-center gap-3 px-4 sm:h-16 sm:grid-cols-[1fr_auto_1fr] sm:px-6 lg:px-10">
          <Link to="/" className="mk-focus-ring w-fit rounded-xl" aria-label="mokaid home">
            <MarketingLogo />
          </Link>

          <nav className="hidden items-center justify-center gap-1 md:flex" aria-label="Primary">
            {navLinks.map((link) => (
              <a
                key={link.href}
                href={link.href}
                className="mk-focus-ring rounded-md px-3.5 py-2 text-[13px] font-medium text-text-secondary transition-colors hover:text-text"
              >
                {link.label}
              </a>
            ))}
          </nav>

          <div className="flex items-center justify-end gap-1.5 sm:gap-2.5">
            {token ? (
              <Link to="/dashboard">
                <Button size="sm" className="min-h-9 px-3.5 sm:min-h-9">
                  Open app <ArrowRight size={14} />
                </Button>
              </Link>
            ) : (
              <>
                <Link to="/login" className="hidden min-[400px]:block">
                  <Button
                    variant="ghost"
                    size="sm"
                    className="min-h-9 text-text-secondary hover:text-text sm:min-h-9"
                  >
                    Sign in
                  </Button>
                </Link>
                <Link to="/signup">
                  <Button size="sm" className="min-h-9 px-3.5 shadow-glow sm:min-h-9 sm:px-4">
                    <span className="sm:hidden">Start</span>
                    <span className="hidden sm:inline">Get started</span>
                    <ArrowRight size={14} />
                  </Button>
                </Link>
              </>
            )}

            <button
              type="button"
              className="mk-focus-ring inline-flex h-9 w-9 items-center justify-center rounded-lg border border-transparent text-text-secondary transition-colors hover:border-white/10 hover:bg-surface/50 hover:text-text md:hidden"
              aria-expanded={menuOpen}
              aria-controls="marketing-mobile-nav"
              aria-label={menuOpen ? "Close menu" : "Open menu"}
              onClick={() => setMenuOpen((v) => !v)}
            >
              {menuOpen ? <X size={18} /> : <Menu size={18} />}
            </button>
          </div>
        </div>

        <div
          id="marketing-mobile-nav"
          className={cn(
            "border-t border-primary/10 bg-bg-deep/90 backdrop-blur-xl md:hidden",
            menuOpen ? "block" : "hidden",
          )}
        >
          <nav
            className="mx-auto flex max-w-7xl flex-col gap-0.5 px-4 py-3 sm:px-6"
            aria-label="Mobile"
          >
            {navLinks.map((link) => (
              <a
                key={link.href}
                href={link.href}
                className="rounded-lg px-3 py-3 text-[15px] font-medium text-text-secondary transition-colors hover:bg-surface/40 hover:text-text"
                onClick={() => setMenuOpen(false)}
              >
                {link.label}
              </a>
            ))}
          </nav>
        </div>
      </header>

      <main>{children}</main>

      <SiteFooter />
    </div>
  );
}

export function Breadcrumbs({ items }: { items: BreadcrumbItem[] }) {
  return (
    <nav aria-label="Breadcrumb" className="mx-auto max-w-6xl px-4 pt-6 sm:px-6">
      <ol className="flex flex-wrap items-center gap-1.5 text-xs text-text-muted">
        {items.map((item, i) => (
          <li key={item.path} className="flex items-center gap-1.5">
            {i > 0 && <span aria-hidden="true">/</span>}
            {i === items.length - 1 ? (
              <span aria-current="page" className="text-text-secondary">
                {item.name}
              </span>
            ) : (
              <a href={item.path} className="transition-colors hover:text-text">
                {item.name}
              </a>
            )}
          </li>
        ))}
      </ol>
    </nav>
  );
}

export function FaqSection({ items, heading = "Frequently asked questions" }: { items: FaqItem[]; heading?: string }) {
  return (
    <section className="mx-auto max-w-3xl px-4 py-12 sm:px-6" aria-labelledby="faq-heading">
      <h2 id="faq-heading" className="mk-seo-display mb-6 text-2xl font-bold">
        {heading}
      </h2>
      <div className="space-y-3">
        {items.map((item) => (
          <details key={item.question} className="mk-card border border-border px-5 py-4">
            <summary className="cursor-pointer list-none text-base font-semibold text-text">
              {item.question}
            </summary>
            <p className="mt-3 text-sm leading-relaxed text-text-secondary">{item.answer}</p>
          </details>
        ))}
      </div>
    </section>
  );
}

export function CtaBanner({
  heading = "Hire your first AI employee today",
  body = "Spin up an autonomous AI teammate in minutes, give it real work, and watch it get done — live, in your 3D office.",
}: {
  heading?: string;
  body?: string;
}) {
  return (
    <section className="mx-auto max-w-6xl px-4 py-16 sm:px-6">
      <div
        className="mk-card relative overflow-hidden border border-primary/15 px-6 py-12 text-center sm:px-12"
        style={{
          background: "linear-gradient(135deg, rgba(124,92,255,0.14) 0%, rgba(18,18,26,1) 60%)",
        }}
      >
        <h2 className="mk-seo-display text-2xl font-bold sm:text-3xl">{heading}</h2>
        <p className="mx-auto mt-3 max-w-xl text-text-secondary">{body}</p>
        <div className="mt-7 flex flex-wrap items-center justify-center gap-3">
          <Link to="/signup">
            <Button className="min-h-11 px-6 shadow-glow">
              Get started free <ArrowRight size={15} />
            </Button>
          </Link>
          <Link to="/">
            <Button variant="ghost" className="min-h-11 px-6 text-text-secondary hover:text-text">
              See the product
            </Button>
          </Link>
        </div>
      </div>
    </section>
  );
}
