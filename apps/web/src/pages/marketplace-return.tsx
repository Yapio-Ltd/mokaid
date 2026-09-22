import { Link } from "@tanstack/react-router";
import { ArrowRight, CheckCircle2 } from "lucide-react";
import { MarketingLayout } from "@/components/seo/marketing-layout";
import { useSeo } from "@/lib/use-seo";

export function MarketplaceReturnPage() {
  useSeo({
    title: "Marketplace payment · Mokaid",
    description: "Your marketplace payment status. Return to the Mokaid desktop app to continue.",
    path: "/marketplace/return",
    noindex: true,
  });

  const params = new URLSearchParams(typeof window !== "undefined" ? window.location.search : "");
  const success = params.get("checkout") === "success";
  const canceled = params.get("checkout") === "canceled";

  return (
    <MarketingLayout>
      <div className="mx-auto flex min-h-[50vh] max-w-lg flex-col items-center justify-center px-4 py-20 text-center">
        <div className="mb-5 flex h-14 w-14 items-center justify-center rounded-2xl border border-primary/25 bg-primary/10">
          <CheckCircle2 className="text-primary-light" size={28} aria-hidden />
        </div>
        <h1 className="text-2xl font-bold tracking-tight text-text sm:text-3xl">
          {canceled ? "Checkout canceled" : success ? "Payment confirmed" : "Return to Mokaid"}
        </h1>
        <p className="mt-4 text-sm leading-relaxed text-text-secondary sm:text-base">
          {canceled
            ? "No charge was made. You can close this tab and reopen Marketplace in the desktop app."
            : success
              ? "Stripe confirmed the payment. Your agent clone appears in the desktop app once fulfillment finishes — usually within a few seconds."
              : "Finish Connect onboarding or checkout in Stripe, then return to the desktop Marketplace tab."}
        </p>
        <div className="mt-8 flex flex-wrap items-center justify-center gap-3">
          <Link
            to="/download"
            className="mk-focus-ring inline-flex min-h-11 items-center gap-2 rounded-md bg-primary px-5 text-sm font-semibold text-white hover:bg-primary-dark"
          >
            Open download <ArrowRight size={14} aria-hidden />
          </Link>
          <a
            href="/#marketplace"
            className="mk-focus-ring inline-flex min-h-11 items-center rounded-md px-4 text-sm font-medium text-text-secondary hover:text-text"
          >
            Back to homepage
          </a>
        </div>
      </div>
    </MarketingLayout>
  );
}
