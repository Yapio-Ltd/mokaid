import { Link } from "@tanstack/react-router";
import { ArrowRight, Home } from "lucide-react";
import { MarketingLayout } from "@/components/seo/marketing-layout";
import { useSeo } from "@/lib/use-seo";

export function NotFoundPage() {
  useSeo({
    title: "Page not found | Mokaid",
    description: "Find your way back to Mokaid.",
    path: window.location.pathname,
    noindex: true,
  });
  return (
    <MarketingLayout>
      <section className="mx-auto flex min-h-[55vh] max-w-3xl flex-col items-start justify-center px-5 py-16 sm:px-6">
        <p className="mb-4 font-mono text-sm text-primary-light">404</p>
        <h1 className="text-3xl font-bold tracking-tight sm:text-5xl">This page has moved on.</h1>
        <p className="mt-5 max-w-lg text-base leading-relaxed text-text-secondary">
          We couldn’t find that address. Explore Mokaid, get the desktop app, or return to your
          account.
        </p>
        <div className="mt-8 flex flex-wrap gap-3">
          <Link
            to="/"
            className="mk-focus-ring inline-flex min-h-12 items-center gap-2 rounded-lg bg-primary px-5 text-sm font-semibold text-white"
          >
            <Home size={17} aria-hidden /> Back to home
          </Link>
          <Link
            to="/download"
            className="mk-focus-ring inline-flex min-h-12 items-center gap-2 rounded-lg border border-white/20 px-5 text-sm font-medium"
          >
            Download Mokaid <ArrowRight size={17} aria-hidden />
          </Link>
        </div>
      </section>
    </MarketingLayout>
  );
}
