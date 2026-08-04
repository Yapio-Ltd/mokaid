const stories = [
  {
    n: "01",
    title: "AI became the default layer of work",
    body: "Models write, reason, and ship alongside every team that competes. Ignoring them is not a strategy — it is lag. The edge is how you organize that capacity.",
  },
  {
    n: "02",
    title: "“Agent” is still a foggy word",
    body: "Pitch decks and products say agentic while the experience stays a chatbox. No desk. No role. No trail your team can trust. Language ran ahead of form.",
  },
  {
    n: "03",
    title: "We give them a body in the office",
    body: "mokaid materializes agents as virtual employees — a seat, a name, tools, memory, and a real workload you can assign like any hire.",
  },
  {
    n: "04",
    title: "They work. You lead.",
    body: "Research, drafts, QA, triage, integrations: agents execute inside your processes. Humans keep judgment, approvals, and direction.",
  },
];

const truths = [
  { k: "Visible", v: "Presence in the office, not hidden in a sidebar" },
  { k: "Accountable", v: "Tasks, status, reviews — like a real teammate" },
  { k: "Collaborative", v: "Humans and agents on the same floor plan" },
];

const stats = [
  { value: 12, suffix: "+", label: "Roles to hire" },
  { value: 87, suffix: "%", label: "Less busywork" },
  { value: 24, suffix: "/7", label: "Always on" },
  { value: 3, suffix: "min", label: "To first agent" },
];

export function WhyMokaid() {
  return (
    <section id="why" className="mk-why relative isolate overflow-hidden">
      <div className="mk-why-glow pointer-events-none absolute inset-0" aria-hidden />
      <div className="mk-why-orb mk-why-orb--l pointer-events-none absolute" aria-hidden />
      <div className="mk-why-orb mk-why-orb--r pointer-events-none absolute" aria-hidden />

      <div className="relative mx-auto max-w-6xl px-4 py-20 sm:px-6 sm:py-28 lg:px-10">
        {/* ── Intro: asymmetric ── */}
        <div className="grid gap-10 lg:grid-cols-12 lg:gap-8 lg:items-end">
          <div data-reveal className="lg:col-span-8">
            <p className="mb-5 text-[11px] font-medium uppercase tracking-[0.22em] text-primary-light/90">
              Why mokaid
            </p>
            <h2 className="max-w-[16ch] text-[2rem] font-bold leading-[1.05] tracking-tight text-text sm:text-5xl sm:leading-[1.02] md:text-[3.35rem]">
              AI is inevitable.
              <br />
              <span className="mk-why-accent-line">A chat is not a hire.</span>
            </h2>
          </div>
          <div data-reveal className="lg:col-span-4 lg:pb-1">
            <p className="max-w-sm text-[15px] leading-relaxed text-text-secondary sm:text-base lg:ml-auto lg:text-right">
              Everyone talks agents. Almost nobody can point to where they sit, what they own, or how
              they work next to people. We make the workforce <em className="not-italic text-primary-light">material</em>.
            </p>
          </div>
        </div>

        {/* ── Pull quote / manifesto strip ── */}
        <div data-reveal className="mk-why-manifesto relative mt-14 sm:mt-20">
          <p className="relative z-[1] max-w-4xl text-xl font-medium leading-snug tracking-tight text-text sm:text-2xl md:text-[1.75rem] md:leading-[1.25]">
            Hire intelligence like people: a desk, a role, a day of work —
            <span className="text-primary-light"> virtual employees that ship for you.</span>
          </p>
        </div>

        {/* ── Timeline (vertical, not cards grid) ── */}
        <div className="mt-16 grid gap-12 lg:mt-24 lg:grid-cols-12 lg:gap-16">
          <div className="lg:col-span-4">
            <div data-reveal className="lg:sticky lg:top-28">
              <p className="text-[11px] font-medium uppercase tracking-[0.2em] text-text-muted">
                The shift
              </p>
              <p className="mt-3 max-w-xs text-lg font-semibold leading-snug tracking-tight text-text">
                From abstract model calls to capacity you can staff.
              </p>
              <ul className="mt-8 space-y-5">
                {truths.map((t) => (
                  <li key={t.k} className="border-l-2 border-primary/40 pl-4">
                    <p className="text-sm font-semibold text-primary-light">{t.k}</p>
                    <p className="mt-0.5 text-sm leading-relaxed text-text-muted">{t.v}</p>
                  </li>
                ))}
              </ul>
            </div>
          </div>

          <ol className="mk-why-timeline relative space-y-0 lg:col-span-8">
            {stories.map((item, i) => (
              <li
                key={item.n}
                data-reveal
                className="mk-why-row relative grid gap-3 border-t border-white/[0.07] py-8 first:border-t-0 first:pt-0 sm:grid-cols-[4.5rem_1fr] sm:gap-8 sm:py-10"
              >
                <span className="font-mono text-sm font-medium tabular-nums text-primary-light/70">
                  {item.n}
                </span>
                <div>
                  <h3 className="text-lg font-semibold tracking-tight text-text sm:text-xl">
                    {item.title}
                  </h3>
                  <p className="mt-2 max-w-xl text-sm leading-relaxed text-text-muted sm:text-[15px]">
                    {item.body}
                  </p>
                  {i === stories.length - 1 && (
                    <p className="mt-5 text-sm font-medium text-primary-light">
                      That is the office for AI and humans — one system of record for the work.
                    </p>
                  )}
                </div>
              </li>
            ))}
          </ol>
        </div>

        {/* ── Stats: single glass rail ── */}
        <div
          data-reveal
          className="mk-why-stats mt-16 grid grid-cols-2 gap-px overflow-hidden rounded-2xl sm:mt-20 md:grid-cols-4"
        >
          {stats.map((stat) => (
            <div key={stat.label} className="mk-why-stat px-5 py-6 text-center sm:px-6 sm:py-8 md:text-left">
              <p className="text-3xl font-bold tracking-tight text-text sm:text-4xl">
                <span data-count={stat.value}>0</span>
                <span className="text-primary-light">{stat.suffix}</span>
              </p>
              <p className="mt-1.5 text-[11px] uppercase tracking-wide text-text-muted sm:text-xs">
                {stat.label}
              </p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
