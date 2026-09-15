import * as React from "react";
import { Link } from "@tanstack/react-router";
import type { LucideIcon } from "lucide-react";
import { cn } from "@/lib/cn";
import { scrollCurrentPageToTop } from "@/lib/navigation-scroll";

interface SocialLink {
  name: string;
  href: string;
}

interface FooterLink {
  name: string;
  Icon: LucideIcon | React.FC<React.SVGProps<SVGSVGElement>>;
  href: string;
}

interface FooterColumn {
  title: string;
  links: FooterLink[];
}

interface DesignCredit {
  href: string;
  name: string;
  logoSrc: string;
  /** Accessible label for the credit link (defaults to "Powered by {name}") */
  label?: string;
}

interface FooterProps extends React.HTMLAttributes<HTMLDivElement> {
  brand: {
    name: string;
    description: string;
  };
  socialLinks: SocialLink[];
  columns: FooterColumn[];
  copyright?: string;
  /** Optional design / powered-by credit shown beside copyright */
  designCredit?: DesignCredit;
}

function isInternalPath(href: string): boolean {
  return href.startsWith("/") && !href.startsWith("//");
}

function FooterAnchor({
  href,
  className,
  children,
}: {
  href: string;
  className?: string;
  children: React.ReactNode;
}) {
  if (isInternalPath(href)) {
    const [path, hash] = href.split("#");
    return (
      <Link to={path} hash={hash} onClick={scrollCurrentPageToTop} className={className}>
        {children}
      </Link>
    );
  }

  const isHttp = href.startsWith("http://") || href.startsWith("https://");
  return (
    <a
      href={href}
      className={className}
      {...(isHttp ? { target: "_blank", rel: "noopener noreferrer" } : {})}
    >
      {children}
    </a>
  );
}

export const Footer = React.forwardRef<HTMLDivElement, FooterProps>(
  ({ className, brand, socialLinks, columns, copyright, designCredit, ...props }, ref) => {
    const creditLabel =
      designCredit?.label ?? (designCredit ? `Powered by ${designCredit.name}` : undefined);

    return (
      <div ref={ref} className={cn("pb-[env(safe-area-inset-bottom)]", className)} {...props}>
        <div className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-10">
          <div className="grid gap-10 lg:grid-cols-[minmax(0,1.15fr)_minmax(0,3.5fr)] lg:gap-12">
            <div className="min-w-0">
              <Link
                to="/"
                onClick={scrollCurrentPageToTop}
                className="mk-focus-ring mk-brand-wordmark inline-flex min-h-11 items-center rounded-md text-2xl font-semibold tracking-tight text-text transition-colors hover:text-primary-light"
              >
                {brand.name}
              </Link>
              <p className="mt-3 max-w-xs text-sm leading-6 text-text-secondary">
                {brand.description}
              </p>

              <p className="mt-3 text-sm text-text-secondary">
                {socialLinks.map((link, index) => (
                  <React.Fragment key={link.name}>
                    <FooterAnchor
                      href={link.href}
                      className="mk-focus-ring inline-flex min-h-11 items-center rounded-sm underline decoration-primary/40 underline-offset-4 transition-colors hover:text-primary-light"
                    >
                      {link.name}
                    </FooterAnchor>
                    {index < socialLinks.length - 1 && " • "}
                  </React.Fragment>
                ))}
              </p>
            </div>

            <div className="grid grid-cols-2 gap-x-6 gap-y-9 sm:grid-cols-4 lg:gap-x-7">
              {columns.map(({ title, links }) => (
                <div key={title} className="min-w-0">
                  <h3 className="text-sm font-semibold text-text">{title}</h3>
                  <ul className="mt-3 space-y-0.5">
                    {links.map(({ name, Icon, href }) => (
                      <li key={name}>
                        <FooterAnchor
                          href={href}
                          className="mk-focus-ring group inline-flex min-h-11 items-start gap-2 rounded-sm py-2.5 text-sm leading-5 text-text-secondary transition-colors hover:text-primary-light"
                        >
                          <Icon
                            aria-hidden
                            className="mt-0.5 h-4 w-4 shrink-0 stroke-[1.75] text-primary-light/80 transition-colors group-hover:text-primary-light"
                          />
                          <span>{name}</span>
                        </FooterAnchor>
                      </li>
                    ))}
                  </ul>
                </div>
              ))}
            </div>
          </div>

          {(copyright || designCredit) && (
            <div className="mt-12 flex flex-col gap-3 border-t border-white/[0.08] pb-8 pt-6 sm:mt-14 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
              {copyright ? (
                <p className="text-xs leading-5 text-text-secondary">{copyright}</p>
              ) : (
                <span />
              )}
              {designCredit && (
                <p className="text-xs text-text-secondary sm:text-right">
                  <a
                    href={designCredit.href}
                    target="_blank"
                    rel="noopener noreferrer"
                    title={creditLabel}
                    aria-label={creditLabel}
                    className="mk-focus-ring group inline-flex min-h-11 items-center gap-1.5 rounded-sm transition-colors hover:text-primary-light"
                  >
                    <span className="font-light tracking-wide">Powered by</span>
                    <img
                      src={designCredit.logoSrc}
                      alt=""
                      width={16}
                      height={15}
                      decoding="async"
                      loading="lazy"
                      className="h-4 w-auto opacity-80 transition-opacity group-hover:opacity-100"
                    />
                    <span className="font-medium text-text/80 transition-colors group-hover:text-primary-light">
                      {designCredit.name}
                    </span>
                  </a>
                </p>
              )}
            </div>
          )}
        </div>
      </div>
    );
  },
);

Footer.displayName = "Footer";
