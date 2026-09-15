import { useEffect, useRef, useState } from "react";
import { Link, useRouterState } from "@tanstack/react-router";
import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import { ArrowRight, ChevronDown, Download, Menu, X } from "lucide-react";
import { cn } from "@/lib/cn";
import { scrollCurrentPageToTop } from "@/lib/navigation-scroll";
import { useAuthStore } from "@/stores/auth-store";

const productLinks = [
  { to: "/", hash: "product", label: "Product" },
  { to: "/ai-employees", label: "AI employees" },
  { to: "/", hash: "connectors", label: "Connectors" },
  { to: "/pricing", label: "Pricing" },
] as const;

const resourceLinks = [
  { to: "/use-cases", label: "Use cases", description: "Find a workflow for your team" },
  { to: "/compare", label: "Compare", description: "Explore the differences" },
  { to: "/blog", label: "Blog", description: "Ideas and practical guides" },
  { to: "/glossary", label: "Glossary", description: "Understand the essentials" },
] as const;

/** The same navigation on the landing page, public content, and downloads. */
export function SiteHeader({ className }: { className?: string }) {
  const token = useAuthStore((state) => state.token);
  const locationKey = useRouterState({ select: (state) => state.location.href });
  const pathname = useRouterState({ select: (state) => state.location.pathname });
  const hash = useRouterState({ select: (state) => state.location.hash });
  const [mobileOpen, setMobileOpen] = useState(false);
  const [resourcesOpen, setResourcesOpen] = useState(false);
  const headerRef = useRef<HTMLElement>(null);
  const mobileTriggerRef = useRef<HTMLButtonElement>(null);
  const resourcesActive = resourceLinks.some((link) => pathname.startsWith(link.to));

  const closeNavigation = (event?: React.MouseEvent<HTMLAnchorElement>) => {
    if (event) scrollCurrentPageToTop(event);
    setMobileOpen(false);
    setResourcesOpen(false);
  };

  useEffect(() => {
    setMobileOpen(false);
    setResourcesOpen(false);
  }, [locationKey]);

  useEffect(() => {
    if (!mobileOpen) return;

    const onPointerDown = (event: Event) => {
      if (event.target instanceof Node && !headerRef.current?.contains(event.target)) {
        setMobileOpen(false);
      }
    };
    const desktop = window.matchMedia("(min-width: 1024px)");
    const onBreakpointChange = () => {
      if (desktop.matches) setMobileOpen(false);
    };
    document.addEventListener("pointerdown", onPointerDown);
    desktop.addEventListener("change", onBreakpointChange);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown);
      desktop.removeEventListener("change", onBreakpointChange);
    };
  }, [mobileOpen]);

  function isActive(to: string, section?: string) {
    return section ? pathname === to && hash === section : pathname.startsWith(to);
  }

  return (
    <header
      ref={headerRef}
      data-site-header
      className={cn(
        "sticky top-0 z-50 border-b border-white/[0.07] bg-bg-deep/95 pt-[env(safe-area-inset-top)] text-text backdrop-blur-xl",
        className,
      )}
      onKeyDown={(event) => {
        if (event.key === "Escape" && mobileOpen) {
          event.preventDefault();
          setMobileOpen(false);
          mobileTriggerRef.current?.focus();
        }
      }}
      onBlur={(event) => {
        if (
          event.relatedTarget instanceof Node &&
          !event.currentTarget.contains(event.relatedTarget)
        ) {
          setMobileOpen(false);
        }
      }}
    >
      <a
        href="#main-content"
        className="mk-focus-ring sr-only z-[70] rounded-md bg-primary px-4 py-3 text-white focus:not-sr-only focus:absolute focus:left-4 focus:top-3"
      >
        Skip to content
      </a>
      <div className="mx-auto flex h-[4.5rem] max-w-7xl items-center justify-between gap-3 px-4 sm:px-6 lg:gap-6 lg:px-10">
        <Link
          to="/"
          onClick={closeNavigation}
          className="mk-focus-ring flex shrink-0 items-center gap-2.5 rounded-xl"
          aria-label="mokaid home"
        >
          <span className="flex h-10 w-10 items-center justify-center rounded-xl border border-primary/25 bg-primary/10">
            <picture>
              <source srcSet="/branding/logo-without-bg.webp" type="image/webp" />
              <img
                src="/branding/logo-without-bg.png"
                alt=""
                width={28}
                height={28}
                className="h-7 w-7 object-contain"
                decoding="async"
              />
            </picture>
          </span>
          <span className="mk-brand-wordmark text-lg tracking-tight">mokaid</span>
        </Link>

        <nav className="hidden items-center gap-0.5 lg:flex" aria-label="Primary">
          {productLinks.map((link) => {
            const section = "hash" in link ? link.hash : undefined;
            const active = isActive(link.to, section);
            return (
              <Link
                key={link.label}
                to={link.to}
                hash={section}
                onClick={closeNavigation}
                aria-current={active ? (section ? "location" : "page") : undefined}
                className={cn(
                  "mk-focus-ring inline-flex min-h-11 items-center rounded-lg px-3 text-sm font-medium transition-colors hover:bg-white/[0.04] hover:text-text",
                  active ? "bg-primary/10 text-primary-light" : "text-text-secondary",
                )}
              >
                {link.label}
              </Link>
            );
          })}

          <DropdownMenu.Root open={resourcesOpen} onOpenChange={setResourcesOpen} modal={false}>
            <DropdownMenu.Trigger asChild>
              <button
                type="button"
                className={cn(
                  "mk-focus-ring inline-flex min-h-11 items-center gap-1.5 rounded-lg px-3 text-sm font-medium transition-colors hover:bg-white/[0.04] hover:text-text",
                  resourcesActive || resourcesOpen
                    ? "bg-primary/10 text-primary-light"
                    : "text-text-secondary",
                )}
              >
                Resources
                <ChevronDown
                  size={14}
                  aria-hidden
                  className={cn(
                    "transition-transform motion-reduce:transition-none",
                    resourcesOpen && "rotate-180",
                  )}
                />
              </button>
            </DropdownMenu.Trigger>
            <DropdownMenu.Portal>
              <DropdownMenu.Content
                align="start"
                sideOffset={8}
                collisionPadding={16}
                className="z-[60] w-72 max-w-[calc(100vw-2rem)] rounded-xl border border-primary/20 bg-bg-deep p-2 text-text"
                aria-label="Resources"
              >
                {resourceLinks.map((link) => (
                  <DropdownMenu.Item asChild key={link.to}>
                    <Link
                      to={link.to}
                      onClick={closeNavigation}
                      aria-current={pathname.startsWith(link.to) ? "page" : undefined}
                      className="group block rounded-lg px-3 py-3 outline-none transition-colors data-[highlighted]:bg-primary/10"
                    >
                      <span className="flex items-center justify-between gap-3 text-sm font-medium">
                        {link.label}
                        <ArrowRight size={14} aria-hidden className="text-primary-light" />
                      </span>
                      <span className="mt-1 block text-sm text-text-secondary">
                        {link.description}
                      </span>
                    </Link>
                  </DropdownMenu.Item>
                ))}
              </DropdownMenu.Content>
            </DropdownMenu.Portal>
          </DropdownMenu.Root>
        </nav>

        <div className="flex shrink-0 items-center gap-2 sm:gap-3">
          <Link
            to={token ? "/account" : "/login"}
            onClick={closeNavigation}
            className="mk-focus-ring hidden min-h-11 items-center rounded-lg px-2 text-sm font-medium text-text-secondary transition-colors hover:text-text sm:inline-flex"
          >
            {token ? "My account" : "Sign in"}
          </Link>
          <Link
            to="/download"
            onClick={closeNavigation}
            className="mk-focus-ring inline-flex min-h-11 items-center justify-center gap-2 rounded-lg bg-primary px-3 text-sm font-semibold text-white transition-colors hover:bg-primary-dark sm:px-4"
          >
            Download
            <Download size={15} aria-hidden className="hidden min-[400px]:block" />
          </Link>
          <button
            ref={mobileTriggerRef}
            type="button"
            className="mk-focus-ring inline-flex h-11 w-11 items-center justify-center rounded-lg text-text-secondary transition-colors hover:bg-primary/10 hover:text-text lg:hidden"
            aria-expanded={mobileOpen}
            aria-controls="site-mobile-nav"
            aria-label={mobileOpen ? "Close menu" : "Open menu"}
            onClick={() => setMobileOpen((open) => !open)}
          >
            {mobileOpen ? <X size={22} aria-hidden /> : <Menu size={22} aria-hidden />}
          </button>
        </div>
      </div>

      <nav
        id="site-mobile-nav"
        aria-label="Mobile navigation"
        hidden={!mobileOpen}
        className="absolute inset-x-0 top-full max-h-[calc(100dvh-4.5rem-env(safe-area-inset-top))] overflow-y-auto border-b border-primary/20 bg-bg-deep px-4 pb-5 pt-2 sm:px-6 lg:hidden"
      >
        <div className="mx-auto max-w-7xl">
          <div className="grid grid-cols-2 gap-1 border-t border-white/[0.07] py-3">
            {productLinks.map((link) => {
              const section = "hash" in link ? link.hash : undefined;
              return (
                <Link
                  key={link.label}
                  to={link.to}
                  hash={section}
                  onClick={closeNavigation}
                  aria-current={
                    isActive(link.to, section) ? (section ? "location" : "page") : undefined
                  }
                  className="mk-focus-ring flex min-h-12 items-center rounded-lg px-3 text-base font-medium text-text-secondary hover:bg-primary/10 hover:text-text aria-[current]:text-primary-light"
                >
                  {link.label}
                </Link>
              );
            })}
          </div>
          <div className="grid grid-cols-2 gap-1 border-t border-white/[0.07] py-3">
            {resourceLinks.map((link) => (
              <Link
                key={link.to}
                to={link.to}
                onClick={closeNavigation}
                aria-current={pathname.startsWith(link.to) ? "page" : undefined}
                className="mk-focus-ring flex min-h-12 items-center rounded-lg px-3 text-base text-text-secondary hover:bg-primary/10 hover:text-text aria-[current]:text-primary-light"
              >
                {link.label}
              </Link>
            ))}
          </div>
          <div className="flex flex-wrap gap-3 border-t border-white/[0.07] pt-4">
            <Link
              to={token ? "/account" : "/login"}
              onClick={closeNavigation}
              className="mk-focus-ring inline-flex min-h-12 flex-1 items-center justify-center gap-2 rounded-lg bg-primary/10 px-4 text-base font-medium text-text"
            >
              {token ? "My account" : "Sign in"}
              <ArrowRight size={16} aria-hidden />
            </Link>
            {!token && (
              <Link
                to="/signup"
                onClick={closeNavigation}
                className="mk-focus-ring inline-flex min-h-12 flex-1 items-center justify-center rounded-lg border border-primary/20 px-4 text-base font-medium text-text"
              >
                Create account
              </Link>
            )}
          </div>
        </div>
      </nav>
    </header>
  );
}
