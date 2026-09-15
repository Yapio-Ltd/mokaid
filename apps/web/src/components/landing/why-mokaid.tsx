const steps = [
  {
    n: "01",
    title: "Give the work a clear owner.",
    body: "Choose an AI employee for the job. Share the brief, attach the context, and define what a useful result looks like.",
  },
  {
    n: "02",
    title: "Follow the work as it happens.",
    body: "Keep tasks and conversations together in the desktop app. Review progress and give feedback when the work needs direction.",
  },
  {
    n: "03",
    title: "Stay in charge of the next step.",
    body: "Review the results with your team. Track consumption, manage your plan, and find your invoices from your web account.",
  },
];

export function WhyMokaid() {
  return (
    <section
      id="why"
      aria-labelledby="why-heading"
      className="bg-black px-5 py-16 sm:px-6 sm:py-24 lg:px-10"
    >
      <div className="mx-auto grid max-w-6xl gap-12 lg:grid-cols-[0.9fr_1.2fr] lg:gap-24">
        <div>
          <h2
            id="why-heading"
            className="max-w-sm text-3xl font-bold leading-tight tracking-tight sm:text-4xl"
          >
            They do the work.
            <br />
            <span className="text-text-secondary">You set the direction.</span>
          </h2>
          <p className="mt-6 max-w-sm text-base leading-relaxed text-text-secondary">
            A useful AI teammate needs more than a chat box. It needs context, responsibility, and a
            place in your workflow.
          </p>
        </div>
        <ol className="divide-y divide-white/10">
          {steps.map((step) => (
            <li
              key={step.n}
              className="grid grid-cols-[2rem_1fr] gap-4 py-7 first:pt-0 last:pb-0 sm:gap-6"
            >
              <span className="pt-1 font-mono text-sm text-primary-light">{step.n}</span>
              <div>
                <h3 className="text-xl font-semibold tracking-tight">{step.title}</h3>
                <p className="mt-3 text-sm leading-relaxed text-text-secondary sm:text-base">
                  {step.body}
                </p>
              </div>
            </li>
          ))}
        </ol>
      </div>
    </section>
  );
}
