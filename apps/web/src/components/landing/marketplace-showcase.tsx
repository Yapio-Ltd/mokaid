const pillars = [
  {
    title: "Sell copies",
    body: "Keep your original agent. Every buyer gets a full clone with linked knowledge. Price it once — sell unlimited times.",
    image: "/landing/marketplace/sell-or-rent.svg",
    alt: "Sell versus rent options",
  },
  {
    title: "Rent monthly or fixed",
    body: "Offer a cancelable monthly subscription, or a prepaid 7, 30, or 90-day term. Access ends when the rental ends.",
    image: "/landing/marketplace/knowledge-transfer.svg",
    alt: "Knowledge traveling with an agent clone",
  },
  {
    title: "Level 10 required",
    body: "It is impossible to put an agent online before level 10. The lock is visible in-app with the levels still to go.",
    image: "/landing/marketplace/level-lock.svg",
    alt: "Agent locked below level 10",
  },
];

export function MarketplaceShowcase() {
  return (
    <section id="marketplace" className="mk-marketplace relative isolate overflow-hidden">
      <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(ellipse_at_20%_0%,rgba(139,93,237,0.18),transparent_55%)]" aria-hidden />
      <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(ellipse_at_90%_80%,rgba(85,190,255,0.08),transparent_45%)]" aria-hidden />

      <div className="relative mx-auto max-w-6xl px-4 py-20 sm:px-6 sm:py-28 lg:px-10">
        <div className="grid items-center gap-12 lg:grid-cols-12 lg:gap-10">
          <div data-reveal className="lg:col-span-6">
            <div className="relative overflow-hidden rounded-3xl border border-primary/25 bg-surface/40 shadow-[0_0_80px_rgba(139,93,237,0.15)]">
              <img
                src="/landing/marketplace/card-listing.svg"
                alt="Marketplace listing for a level 10 research agent"
                width={640}
                height={420}
                className="h-auto w-full"
                loading="lazy"
                decoding="async"
              />
            </div>
          </div>

          <div data-reveal className="lg:col-span-6">
            <p className="mb-5 text-[11px] font-medium uppercase tracking-[0.22em] text-primary-light/90">
              Marketplace
            </p>
            <h2 className="max-w-[18ch] text-[2rem] font-bold leading-[1.05] tracking-tight text-text sm:text-5xl sm:leading-[1.02]">
              Put trained agents to work for other teams.
            </h2>
            <p className="mt-5 max-w-xl text-[15px] leading-relaxed text-text-secondary sm:text-base">
              Once an agent hits level 10, list it with its linked knowledge. Buyers get a ready
              specialist. You get paid through Stripe — Mokaid takes 15% on every sale, monthly
              rental, and fixed term.
            </p>
            <ul className="mt-8 space-y-3 text-sm text-text-secondary">
              <li className="flex gap-3">
                <span className="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-primary-light" aria-hidden />
                <span>
                  <strong className="font-semibold text-text">Knowledge included</strong> — agent-scoped
                  items, chunks, and graph. Conversations, tasks, Drive files, and connectors stay
                  private.
                </span>
              </li>
              <li className="flex gap-3">
                <span className="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-primary-light" aria-hidden />
                <span>
                  <strong className="font-semibold text-text">Real payouts</strong> — Stripe Connect
                  Express for creators; application fee on each Checkout payment.
                </span>
              </li>
              <li className="flex gap-3">
                <span className="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-primary-light" aria-hidden />
                <span>
                  <strong className="font-semibold text-text">Snapshot at purchase</strong> — the buyer
                  receives the agent as it was when they paid. Renewals extend access; they do not
                  re-sync knowledge.
                </span>
              </li>
            </ul>
            <a
              href="/download"
              className="mk-focus-ring mt-8 inline-flex min-h-11 items-center gap-2 rounded-md bg-primary px-5 text-sm font-semibold text-white hover:bg-primary-dark"
            >
              Download the desktop app
            </a>
          </div>
        </div>

        <div className="mt-16 grid gap-6 md:grid-cols-3 md:gap-5 lg:mt-20">
          {pillars.map((pillar) => (
            <article
              key={pillar.title}
              data-reveal
              className="group overflow-hidden rounded-2xl border border-white/10 bg-surface/30 transition-[border-color,transform] duration-300 hover:-translate-y-0.5 hover:border-primary/35"
            >
              <div className="border-b border-white/5 bg-bg-deep/60">
                <img
                  src={pillar.image}
                  alt={pillar.alt}
                  width={640}
                  height={420}
                  className="h-auto w-full opacity-95 transition-opacity group-hover:opacity-100"
                  loading="lazy"
                  decoding="async"
                />
              </div>
              <div className="p-5 sm:p-6">
                <h3 className="text-lg font-semibold tracking-tight text-text">{pillar.title}</h3>
                <p className="mt-2 text-sm leading-relaxed text-text-secondary">{pillar.body}</p>
              </div>
            </article>
          ))}
        </div>
      </div>
    </section>
  );
}
