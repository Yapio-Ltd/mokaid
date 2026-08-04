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

interface FooterProps extends React.HTMLAttributes<HTMLDivElement> {
  brand: {
    name: string;
    description: string;
  };
  socialLinks: SocialLink[];
  columns: FooterColumn[];
  copyright?: string;
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
  ({ className, brand, socialLinks, columns, copyright, ...props }, ref) => {
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

          {copyright && (
            <div className="mt-14 border-t border-white/[0.05] pb-8 pt-6 sm:mt-16">
              <p className="text-xs text-text-muted">{copyright}</p>
            </div>
          )}
        </div>
      </div>
    );
  },
);

Footer.displayName = "Footer";
