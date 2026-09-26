import { useEffect, useRef, useState, type ComponentRef } from "react";
import { Link, useRouterState } from "@tanstack/react-router";
import { ArrowRight, Menu, X } from "lucide-react";
import { RandomLetterSwap } from "@/components/ui/random-letter-swap";
import { cn } from "@/lib/cn";
import { accountEntryPath } from "@/lib/desktop-rollout";
import { useAuthStore } from "@/stores/auth-store";

const navigation = [
  { href: "/#product", label: "Experience" },
  { href: "/pricing", label: "Pricing" },
] as const;

/** One navigation for every public page; only the hero has a transparent overlay. */
export function SiteHeader({ overlayHero = false }: { overlayHero?: boolean }) {
  const pathname = useRouterState({ select: (state) => state.location.pathname });
  const token = useAuthStore((state) => state.token);
  const [scrolled, setScrolled] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const menuRef = useRef<ComponentRef<"details">>(null);
  const toggleRef = useRef<ComponentRef<"summary">>(null);
  const accountHref = token ? accountEntryPath() : "/login";
  const accountLabel = token ? "My account" : "Sign in";

  const closeMenu = () => {
    if (menuRef.current) menuRef.current.open = false;
    setMenuOpen(false);
  };

  useEffect(() => {
    if (menuRef.current) menuRef.current.open = false;
    setMenuOpen(false);
  }, [pathname]);

  useEffect(() => {
    const desktop = window.matchMedia("(min-width: 768px)");
    const onViewportChange = () => {
      if (desktop.matches) {
        if (menuRef.current) menuRef.current.open = false;
        setMenuOpen(false);
      }
    };
    desktop.addEventListener("change", onViewportChange);
    return () => desktop.removeEventListener("change", onViewportChange);
  }, []);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      // Native details opens before its asynchronous toggle event reaches React.
      if (event.key !== "Escape" || !menuRef.current?.open) return;
      menuRef.current.open = false;
      setMenuOpen(false);
      toggleRef.current?.focus();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  useEffect(() => {
    if (!overlayHero) return;
    let frame = 0;
    const onScroll = () => {
      if (frame) return;
      frame = window.requestAnimationFrame(() => {
        frame = 0;
        setScrolled(window.scrollY > window.innerHeight * 0.55);
      });
    };
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll, { passive: true });
    return () => {
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", onScroll);
      if (frame) window.cancelAnimationFrame(frame);
    };
  }, [overlayHero]);

  const links = navigation.map((link) => ({
    ...link,
    href: link.href === "/#product" && pathname === "/" ? "#product" : link.href,
    current: pathname === link.href,
  }));

  return (
    <header
      data-site-header
      data-landing-header={overlayHero ? "" : undefined}
      className={cn(
        "mk-site-header top-0 z-50 border-b pt-[env(safe-area-inset-top)] transition-[background-color,backdrop-filter,box-shadow,border-color] duration-300 motion-reduce:transition-none",
        overlayHero ? "fixed inset-x-0" : "sticky",
        !overlayHero || scrolled || menuOpen
          ? "mk-header-scrolled border-primary/15 shadow-[0_8px_32px_rgba(0,0,0,0.35)]"
          : "border-transparent bg-transparent backdrop-blur-none",
      )}
    >
      <div className="mx-auto grid h-14 max-w-7xl grid-cols-[1fr_auto] items-center gap-3 px-4 sm:h-16 md:grid-cols-[1fr_auto_1fr] sm:px-6 lg:px-10">
        <Link
          to="/"
          onClick={closeMenu}
          className="mk-focus-ring w-fit rounded-xl"
          aria-label="mokaid home"
        >
          <span className="flex items-center gap-2.5 sm:gap-3">
            <span className="relative flex h-9 w-9 items-center justify-center rounded-xl border border-primary/20 bg-primary/10 sm:h-10 sm:w-10">
              <picture>
                <source srcSet="/branding/logo-without-bg.webp" type="image/webp" />
                <img
                  src="/branding/logo-without-bg.png"
                  alt=""
                  className="h-6 w-6 object-contain sm:h-7 sm:w-7"
                  width={28}
                  height={28}
                  decoding="async"
                />
              </picture>
            </span>
            <span className="mk-brand-wordmark hidden text-[15px] tracking-tight text-text min-[400px]:inline sm:text-[17px]">
              mokaid
            </span>
          </span>
        </Link>

        <nav className="hidden items-center justify-center gap-1 md:flex" aria-label="Primary">
          {links.map((link) => (
            <a
              key={link.label}
              href={link.href}
              aria-current={link.current ? "page" : undefined}
              className={cn(
                "mk-focus-ring rounded-md px-3.5 py-2 text-[13px] font-medium transition-colors hover:text-text",
                link.current
                  ? "text-text underline decoration-primary underline-offset-8"
                  : "text-text-secondary",
              )}
            >
              <RandomLetterSwap
                label={link.label}
                staggerDuration={0.025}
                transition={{ duration: 0.55, type: "spring", bounce: 0 }}
              />
            </a>
          ))}
        </nav>

        <div className="flex items-center justify-end gap-1.5 sm:gap-2.5">
          <Link
            to={accountHref}
            onClick={closeMenu}
            className="mk-focus-ring hidden min-h-10 items-center whitespace-nowrap rounded-md px-3 text-sm font-medium text-text-secondary hover:text-text md:inline-flex"
          >
            {accountLabel}
          </Link>
          <Link
            to="/download"
            onClick={closeMenu}
            aria-current={pathname === "/download" ? "page" : undefined}
            className={cn(
              "mk-focus-ring inline-flex min-h-10 items-center gap-2 rounded-md bg-primary px-3.5 text-sm font-semibold text-white hover:bg-primary-dark",
              pathname === "/download" && "underline underline-offset-4",
            )}
          >
            Download <ArrowRight size={14} aria-hidden />
          </Link>

          {/* Native disclosure keeps navigation available in the prerender without JavaScript. */}
          <details
            ref={menuRef}
            className="group md:hidden"
            onToggle={(event) => setMenuOpen(event.currentTarget.open)}
          >
            <summary
              ref={toggleRef}
              aria-label={menuOpen ? "Close menu" : "Open menu"}
              aria-controls="site-mobile-nav"
              className="mk-focus-ring flex h-10 w-10 cursor-pointer list-none items-center justify-center rounded-lg border border-transparent text-text-secondary transition-colors hover:border-white/10 hover:bg-surface/50 hover:text-text [&::-webkit-details-marker]:hidden"
            >
              <Menu size={18} className="group-open:hidden" aria-hidden />
              <X size={18} className="hidden group-open:block" aria-hidden />
            </summary>
            <nav
              id="site-mobile-nav"
              aria-label="Mobile"
              className="absolute inset-x-0 top-full border-y border-primary/15 bg-bg-deep px-4 py-3 shadow-xl sm:px-6"
            >
              {links.map((link) => (
                <a
                  key={link.label}
                  href={link.href}
                  onClick={closeMenu}
                  aria-current={link.current ? "page" : undefined}
                  className={cn(
                    "mk-focus-ring block rounded-lg px-3 py-3 text-[15px] font-medium transition-colors hover:bg-surface/40 hover:text-text",
                    link.current
                      ? "text-text underline decoration-primary underline-offset-4"
                      : "text-text-secondary",
                  )}
                >
                  {link.label}
                </a>
              ))}
              <Link
                to={accountHref}
                onClick={closeMenu}
                className="mk-focus-ring block rounded-lg px-3 py-3 text-[15px] font-medium text-text-secondary transition-colors hover:bg-surface/40 hover:text-text"
              >
                {accountLabel}
              </Link>
            </nav>
          </details>
        </div>
      </div>
    </header>
  );
}
