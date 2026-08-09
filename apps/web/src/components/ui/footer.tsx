import * as React from "react";
import { Link } from "@tanstack/react-router";
import type { LucideIcon } from "lucide-react";
import { cn } from "@/lib/cn";

interface SocialLink {
  name: string;
  href: string;
}

interface FooterLink {
  name: string;
  Icon: LucideIcon | React.FC<React.SVGProps<SVGSVGElement>>;
  href?: string;
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
    return (
      <Link to={href} className={className}>
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
  (
    { className, brand, socialLinks, columns, copyright, designCredit, ...props },
    ref,
  ) => {
    const creditLabel =
      designCredit?.label ?? (designCredit ? `Powered by ${designCredit.name}` : undefined);

    return (
      <div
        ref={ref}
        className={cn("pb-[env(safe-area-inset-bottom)]", className)}
        {...props}
      >
        <div className="mx-auto max-w-screen-xl px-4 lg:px-8">
          <div className="grid grid-cols-1 lg:grid-cols-12">
            <div className="lg:col-span-4">
              <Link
                to="/"
                className="mk-brand-wordmark text-xl font-semibold tracking-tight text-text transition-colors hover:text-primary-light"
              >
                {brand.name}
              </Link>
              <p className="mt-2 max-w-sm text-sm text-text-muted">{brand.description}</p>

              <p className="mt-3.5 text-sm font-light text-text-muted">
                {socialLinks.map((link, index) => (
                  <React.Fragment key={link.name}>
                    <FooterAnchor
                      href={link.href}
                      className="transition-colors hover:text-primary-light"
                    >
                      {link.name}
                    </FooterAnchor>
                    {index < socialLinks.length - 1 && " • "}
                  </React.Fragment>
                ))}
              </p>
            </div>

            <div className="mt-12 grid grid-cols-2 gap-x-4 gap-y-10 sm:mt-16 md:grid-cols-3 lg:col-span-8 lg:mt-0 lg:justify-items-end lg:gap-y-0">
              {columns.map(({ title, links }) => (
                <div key={title} className="min-w-0">
                  <h3 className="text-xs font-semibold uppercase tracking-wider text-primary-light/90">
                    {title}
                  </h3>
                  <ul className="mt-4 space-y-2.5">
                    {links.map(({ name, Icon, href }) => (
                      <li key={name}>
                        <FooterAnchor
                          href={href || "#"}
                          className="group inline-flex min-h-10 items-center text-sm text-text-muted transition-all hover:text-primary-light sm:min-h-0"
                        >
                          <Icon className="mr-1.5 inline h-4 w-4 shrink-0 stroke-2 text-text-muted transition-colors group-hover:text-primary-light" />
                          <span className="truncate">{name}</span>
                        </FooterAnchor>
                      </li>
                    ))}
                  </ul>
                </div>
              ))}
            </div>
          </div>

          {(copyright || designCredit) && (
            <div className="mt-14 flex flex-col gap-3 border-t border-white/[0.05] pb-8 pt-6 sm:mt-16 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
              {copyright ? (
                <p className="text-xs text-text-muted">{copyright}</p>
              ) : (
                <span />
              )}
              {designCredit && (
                <p className="text-xs text-text-muted sm:text-right">
                  <a
                    href={designCredit.href}
                    target="_blank"
                    rel="noopener noreferrer"
                    title={creditLabel}
                    aria-label={creditLabel}
                    className="group inline-flex items-center gap-1.5 rounded-sm transition-colors hover:text-primary-light focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50 focus-visible:ring-offset-2 focus-visible:ring-offset-transparent"
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
