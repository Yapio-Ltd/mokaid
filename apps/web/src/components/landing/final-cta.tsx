import { Link } from "@tanstack/react-router";
import { ArrowRight } from "lucide-react";

/** Final download invitation, readable with or without motion. */
export function FinalCta() {
  return (
    <section className="mk-final-cta relative isolate">
      <div className="mk-final-cta-glow pointer-events-none absolute inset-0" aria-hidden />

      <div className="relative mx-auto max-w-5xl px-4 py-14 sm:px-6 sm:py-16 md:py-20">
        <div
          data-cta-panel
          className="mk-final-cta-panel grid items-center gap-8 p-7 sm:gap-10 sm:p-10 md:grid-cols-12 md:p-12"
        >
          <div className="md:col-span-7 lg:col-span-8">
            <picture>
              <source srcSet="/branding/logo-without-bg.webp" type="image/webp" />
              <img
                src="/branding/logo-without-bg.png"
                alt=""
                aria-hidden
                width={40}
                height={40}
                decoding="async"
                loading="lazy"
                className="mb-5 h-10 w-10 object-contain opacity-90"
              />
            </picture>

            <h2 className="max-w-xl text-[1.65rem] font-bold leading-[1.12] tracking-tight text-text sm:text-3xl md:text-[2.4rem] md:leading-[1.1]">
              Ready to meet your <span className="text-primary-light">new teammates</span>?
            </h2>

            <p className="mt-3.5 max-w-md text-sm leading-relaxed text-text-secondary md:text-[15px]">
              Bring your AI team together in Mokaid Desktop. Manage your usage, subscription and
              payments from your account on the web.
            </p>
          </div>

          <div className="flex flex-col items-stretch gap-3 md:col-span-5 md:items-end lg:col-span-4">
            <p className="text-[12px] text-text-secondary md:text-right">
              Your office lives in the desktop app.
            </p>

            <Link
              to="/download"
              className="mk-focus-ring inline-flex min-h-12 w-full items-center justify-center gap-2 rounded-lg bg-primary px-6 text-sm font-semibold text-white transition-colors hover:bg-primary-dark md:w-auto"
            >
              Download Mokaid <ArrowRight size={16} aria-hidden />
            </Link>

            <p className="text-center text-[11px] text-text-secondary md:text-right">
              macOS · Windows
            </p>
          </div>
        </div>
      </div>
    </section>
  );
}
