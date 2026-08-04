import type { LucideIcon } from "lucide-react";
import { Link } from "@tanstack/react-router";
import { ArrowLeft } from "lucide-react";
import {
  CONTACT_EMAIL,
  EFFECTIVE_DATE,
  LEGAL_ADDRESS_LINES,
  LEGAL_ENTITY_NAME,
  COMPANY_REGISTRATION_NUMBER,
  PRODUCT_DISPLAY,
} from "@/lib/legal-config";

const FOOTER_LINKS = [
  { to: "/privacy" as const, label: "Privacy Policy" },
  { to: "/terms" as const, label: "Terms of Service" },
  { to: "/refund" as const, label: "Refund & Cancellation" },
  { to: "/cookies" as const, label: "Cookies" },
  { to: "/legal" as const, label: "Legal Notice" },
];

export function LegalDocLayout({
  icon: Icon,
  title,
  intro,
  children,
  excludeFooterLink,
}: {
  icon: LucideIcon;
  title: string;
  intro?: React.ReactNode;
  children: React.ReactNode;
  /** Path already open — omit from footer cross-links */
  excludeFooterLink?: (typeof FOOTER_LINKS)[number]["to"];
}) {
  return (
    <div className="min-h-full bg-bg-deep text-text">
      <header className="sticky top-0 z-10 bg-bg-deep/80 backdrop-blur-md">
        <div className="mx-auto flex max-w-3xl items-center justify-between px-5 py-4">
          <Link
            to="/"
            className="mk-focus-ring flex items-center gap-1.5 rounded-md px-2 py-1.5 text-xs text-text-muted transition-colors hover:text-text"
          >
            <ArrowLeft size={13} /> Back to site
          </Link>
          <Link to="/" className="flex items-center gap-2">
            <img
              src="/branding/logo-without-bg.png"
              alt={PRODUCT_DISPLAY}
              className="h-7 w-7 object-contain"
            />
            <span className="text-sm font-bold tracking-tight text-text">
              {PRODUCT_DISPLAY}
            </span>
          </Link>
        </div>
      </header>

      <main className="mx-auto max-w-3xl px-5 py-16">
        <div className="mb-12">
          <div className="mb-4 inline-flex items-center gap-2 rounded-full border border-primary/30 bg-primary/10 px-3 py-1 text-xs font-medium text-primary-light">
            <Icon size={12} />
            Legal document
          </div>
          <h1 className="text-4xl font-bold tracking-tight text-text">{title}</h1>
          <p className="mt-4 text-sm text-text-muted">Last updated: {EFFECTIVE_DATE}</p>
          {intro}
        </div>

        <div className="space-y-12">{children}</div>

        <div className="mt-16 flex flex-col items-center gap-3 pt-8 text-xs text-text-muted">
          <p>
            © {new Date().getFullYear()} {LEGAL_ENTITY_NAME}. All rights reserved. {PRODUCT_DISPLAY}{" "}
            is a product of {LEGAL_ENTITY_NAME}.
          </p>
          <div className="flex flex-wrap items-center justify-center gap-x-4 gap-y-2">
            {FOOTER_LINKS.filter((l) => l.to !== excludeFooterLink).map((link, i, arr) => (
              <span key={link.to} className="contents">
                <Link to={link.to} className="transition-colors hover:text-text">
                  {link.label}
                </Link>
                {i < arr.length - 1 && <span>·</span>}
              </span>
            ))}
            <span>·</span>
            <Link to="/" className="transition-colors hover:text-text">
              Back to home
            </Link>
          </div>
        </div>
      </main>
    </div>
  );
}

export function SectionTitle({ index, title }: { index: string; title: string }) {
  return (
    <div className="mb-4 flex items-start gap-3">
      <span className="mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-md bg-primary/15 text-[11px] font-bold text-primary-light">
        {index}
      </span>
      <h2 className="text-lg font-semibold tracking-tight text-text">{title}</h2>
    </div>
  );
}

export function Prose({
  children,
  className,
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <p className={`text-sm leading-relaxed text-text-secondary ${className ?? ""}`}>{children}</p>
  );
}

export function SubList({ items }: { items: string[] | { label: string; detail: string }[] }) {
  const isLabeled =
    items.length > 0 && typeof items[0] === "object" && items[0] !== null && "label" in items[0];

  if (isLabeled) {
    const labeled = items as { label: string; detail: string }[];
    return (
      <ul className="mt-3 space-y-2">
        {labeled.map(({ label, detail }) => (
          <li key={label} className="flex gap-3 text-sm">
            <span className="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-primary/60" />
            <span className="text-text-secondary">
              <span className="font-medium text-text">{label}</span> — {detail}
            </span>
          </li>
        ))}
      </ul>
    );
  }

  return (
    <ul className="mt-3 space-y-2">
      {(items as string[]).map((item, i) => (
        <li key={i} className="flex gap-3 text-sm text-text-secondary">
          <span className="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-primary/60" />
          <span>{item}</span>
        </li>
      ))}
    </ul>
  );
}

export function EntityContactCard({ attention }: { attention?: string }) {
  return (
    <div className="mt-4 rounded-lg border border-border bg-surface px-5 py-4 text-sm text-text-secondary">
      <p>
        <strong className="text-text">{LEGAL_ENTITY_NAME}</strong>
      </p>
      {attention && <p>Attention: {attention}</p>}
      {LEGAL_ADDRESS_LINES.map((line) => (
        <p key={line}>{line}</p>
      ))}
      {COMPANY_REGISTRATION_NUMBER ? (
        <p>Registration no.: {COMPANY_REGISTRATION_NUMBER}</p>
      ) : null}
      <p className="mt-2">
        Email:{" "}
        <a href={`mailto:${CONTACT_EMAIL}`} className="text-primary-light hover:underline">
          {CONTACT_EMAIL}
        </a>
      </p>
    </div>
  );
}
