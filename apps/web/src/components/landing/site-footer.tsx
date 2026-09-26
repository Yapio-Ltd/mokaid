import {
  BadgeDollarSign,
  Blocks,
  BookOpen,
  BookText,
  Bot,
  Building2,
  Cookie,
  Download,
  GitCompare,
  Handshake,
  Lightbulb,
  LogIn,
  Rocket,
  RotateCcw,
  Scale,
  Users,
} from "lucide-react";
import { Footer } from "@/components/ui/footer";
import { CONTACT_EMAIL, LEGAL_ENTITY_NAME } from "@/lib/legal-config";

const RESOURCE_LINKS = [
  { name: "AI Employees", Icon: Users, href: "/ai-employees" },
  { name: "Use Cases", Icon: Lightbulb, href: "/use-cases" },
  { name: "Compare", Icon: GitCompare, href: "/compare" },
  { name: "Blog", Icon: BookOpen, href: "/blog" },
  { name: "Glossary", Icon: BookText, href: "/glossary" },
];

export function SiteFooter({ compact = false }: { compact?: boolean }) {
  if (compact) {
    return (
      <footer className="mk-site-footer border-t border-white/10 bg-bg-deep px-5 py-8 sm:px-8">
        <div className="mx-auto flex max-w-7xl flex-col gap-6 sm:flex-row sm:items-center sm:justify-between">
          <a href="/" className="mk-focus-ring mk-brand-wordmark w-fit rounded text-lg text-text">
            mokaid
          </a>
          <nav
            aria-label="Footer"
            className="flex flex-wrap gap-x-5 gap-y-3 text-xs text-text-secondary"
          >
            {[
              { label: "Pricing", href: "/pricing" },
              { label: "Download", href: "/download" },
              { label: "Privacy", href: "/privacy" },
              { label: "Terms", href: "/terms" },
              { label: "Cookies", href: "/cookies" },
              { label: "Refunds", href: "/refund" },
              { label: "Legal", href: "/legal" },
              { label: "Contact", href: `mailto:${CONTACT_EMAIL}` },
            ].map(({ label, href }) => (
              <a
                key={href}
                href={href}
                className="mk-focus-ring rounded transition-colors hover:text-text"
              >
                {label}
              </a>
            ))}
          </nav>
        </div>
        <nav
          aria-label="Footer resources"
          className="mx-auto mt-5 flex max-w-7xl flex-wrap gap-x-5 gap-y-2 text-xs text-text-secondary"
        >
          {RESOURCE_LINKS.map(({ name, href }) => (
            <a
              key={href}
              href={href}
              className="mk-focus-ring rounded transition-colors hover:text-text"
            >
              {name}
            </a>
          ))}
        </nav>
        <p className="mx-auto mt-6 max-w-7xl text-[11px] text-text-muted">
          © {new Date().getFullYear()} {LEGAL_ENTITY_NAME}. All rights reserved.
        </p>
      </footer>
    );
  }

  return (
    <div className="mk-site-footer relative isolate overflow-hidden">
      {/* Soft atmospheric top fade — no hard white line */}
      <div
        className="pointer-events-none absolute inset-x-0 -top-24 h-32 bg-gradient-to-b from-transparent via-primary/[0.04] to-transparent"
        aria-hidden
      />
      <div
        className="pointer-events-none absolute -bottom-20 left-1/4 h-48 w-72 -translate-x-1/2 rounded-full bg-primary/10 blur-[80px]"
        aria-hidden
      />
      <div
        className="pointer-events-none absolute -bottom-16 right-0 h-40 w-56 rounded-full bg-[rgba(100,180,255,0.08)] blur-[70px]"
        aria-hidden
      />

      <Footer
        className="relative mk-glass-footer pt-12 sm:pt-16"
        brand={{
          name: "mokaid",
          description: "The workspace for AI and human employees. Built with care.",
        }}
        socialLinks={[
          {
            name: "Contact",
            href: `mailto:${CONTACT_EMAIL}`,
          },
        ]}
        columns={[
          {
            title: "Product",
            links: [
              {
                name: "Experience",
                Icon: Blocks,
                href: "/#product",
              },
              {
                name: "AI employees",
                Icon: Bot,
                href: "/ai-employees",
              },
              {
                name: "Pricing",
                Icon: BadgeDollarSign,
                href: "/pricing",
              },
              { name: "Download desktop", Icon: Download, href: "/download" },
            ],
          },
          {
            title: "Resources",
            links: RESOURCE_LINKS,
          },
          {
            title: "Account",
            links: [
              {
                name: "Sign in",
                Icon: LogIn,
                href: "/login",
              },
              {
                name: "Get started",
                Icon: Rocket,
                href: "/signup",
              },
            ],
          },
          {
            title: "Legal",
            links: [
              {
                name: "Privacy Policy",
                Icon: Scale,
                href: "/privacy",
              },
              {
                name: "Terms of Service",
                Icon: Handshake,
                href: "/terms",
              },
              {
                name: "Refund & Cancellation",
                Icon: RotateCcw,
                href: "/refund",
              },
              {
                name: "Cookies",
                Icon: Cookie,
                href: "/cookies",
              },
              {
                name: "Legal Notice",
                Icon: Building2,
                href: "/legal",
              },
            ],
          },
        ]}
        copyright={`© ${new Date().getFullYear()} ${LEGAL_ENTITY_NAME}. All rights reserved.`}
        designCredit={{
          href: "https://www.yapio.io/",
          name: "Yapio",
          logoSrc: "/branding/icononly_nav.webp",
          label: "Powered by Yapio — design and product engineering",
        }}
      />
    </div>
  );
}
