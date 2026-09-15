import { Link } from "@tanstack/react-router";
import { ArrowRight, Code2, Palette, Search, ShieldCheck } from "lucide-react";

const agents = [
  {
    name: "Ava",
    role: "Design",
    icon: Palette,
    title: "Turn a brief into something tangible.",
    body: "Explore visual directions, shape interfaces, and build a consistent design system.",
    skills: ["UI / UX", "Design systems", "Visual assets"],
  },
  {
    name: "Nora",
    role: "Legal",
    icon: ShieldCheck,
    title: "Make the fine print easier to review.",
    body: "Summarize agreements, surface clauses to examine, and prepare questions for your legal team.",
    skills: ["Contract review", "Risk summaries", "Research"],
  },
  {
    name: "Dr. Kai",
    role: "Research",
    icon: Search,
    title: "Go from questions to useful context.",
    body: "Investigate a topic, compare sources, and turn findings into a clear working brief.",
    skills: ["Deep research", "Market analysis", "Synthesis"],
  },
  {
    name: "Alex",
    role: "Engineering",
    icon: Code2,
    title: "Move the next implementation forward.",
    body: "Break down specifications, investigate bugs, and prepare code for your team to review.",
    skills: ["Code review", "Debugging", "Architecture"],
  },
];

export function AgentTour() {
  return (
    <section
      id="agents"
      className="border-y border-white/[0.07] bg-bg-deep px-5 py-16 sm:px-6 sm:py-24 lg:px-10"
      aria-labelledby="agents-heading"
    >
      <div className="mx-auto max-w-6xl">
        <div className="mb-10 flex flex-col justify-between gap-6 sm:flex-row sm:items-end">
          <div>
            <h2
              id="agents-heading"
              className="max-w-2xl text-3xl font-bold leading-tight tracking-tight sm:text-5xl"
            >
              Different strengths.
              <br />
              One team, led by you.
            </h2>
          </div>
          <Link
            to="/ai-employees"
            className="mk-focus-ring inline-flex min-h-11 w-fit shrink-0 items-center gap-2 rounded-md text-sm font-semibold text-primary-light"
          >
            Meet the AI employees <ArrowRight size={17} aria-hidden />
          </Link>
        </div>
        <div className="grid sm:grid-cols-2 sm:gap-x-10 lg:gap-x-16">
          {agents.map(({ name, role, icon: Icon, title, body, skills }) => (
            <article key={name} className="border-t border-white/10 py-8 sm:py-10">
              <div className="mb-6 flex items-center gap-3">
                <span className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl border border-primary/25 bg-primary/10 text-primary-light">
                  <Icon size={21} aria-hidden />
                </span>
                <div>
                  <h3 className="text-lg font-semibold">{name}</h3>
                  <p className="text-sm text-text-secondary">AI · {role}</p>
                </div>
              </div>
              <p className="max-w-md text-xl font-medium leading-snug tracking-tight">{title}</p>
              <p className="mt-3 max-w-md text-sm leading-relaxed text-text-secondary sm:text-base">
                {body}
              </p>
              <ul className="mt-5 flex flex-wrap gap-x-4 gap-y-2 text-xs text-primary-light">
                {skills.map((skill) => (
                  <li key={skill}>{skill}</li>
                ))}
              </ul>
            </article>
          ))}
        </div>
      </div>
    </section>
  );
}
