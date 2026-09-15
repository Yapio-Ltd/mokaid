import { useState } from "react";
import { Link } from "@tanstack/react-router";
import { ArrowRight } from "lucide-react";
import * as Tabs from "@radix-ui/react-tabs";

const views = [
  {
    id: "overview",
    label: "The whole team",
    title: "One place to see the work.",
    body: "Meet your AI employees in the desktop office. Give each one a role, assign a task, and follow the work alongside your team.",
    x: 50,
    y: 50,
    zoom: 1,
  },
  {
    id: "floor",
    label: "At their desks",
    title: "A role. A brief. A clear next step.",
    body: "Organize specialists around the work you need to get done, from research and design to engineering and operations.",
    x: 45,
    y: 60,
    zoom: 1.35,
  },
  {
    id: "meeting",
    label: "Working together",
    title: "Keep people in the conversation.",
    body: "Bring context, feedback, and decisions into a shared workspace. Your team sets the direction and reviews the results.",
    x: 90,
    y: 20,
    zoom: 1.6,
  },
] as const;

export function OfficeTour() {
  const [active, setActive] = useState<string>(views[0].id);
  const view = views.find((item) => item.id === active) ?? views[0];
  return (
    <section
      id="product"
      className="relative border-y border-white/[0.07] bg-bg-deep px-5 py-16 sm:px-6 sm:py-24 lg:px-10"
      aria-labelledby="product-heading"
    >
      <div className="mx-auto max-w-6xl">
        <div className="mb-10 grid items-end gap-6 lg:grid-cols-[1.2fr_1fr] lg:gap-16">
          <div>
            <h2
              id="product-heading"
              className="max-w-xl text-3xl font-bold leading-tight tracking-tight sm:text-5xl"
            >
              Your team has a place.
              <br />
              <span className="text-text-secondary">Your work has a home.</span>
            </h2>
          </div>
          <p className="max-w-md text-base leading-relaxed text-text-secondary lg:pb-1">
            The desktop app brings your AI employees, tasks, and tools together. Your web account
            keeps usage and billing within reach.
          </p>
        </div>
        <Tabs.Root value={active} onValueChange={setActive}>
          <Tabs.List aria-label="Explore the desktop office" className="mb-6 flex flex-wrap gap-2">
            {views.map((item) => (
              <Tabs.Trigger
                key={item.id}
                value={item.id}
                className="mk-focus-ring min-h-11 rounded-lg border border-white/10 px-4 py-2 text-sm text-text-secondary transition-colors hover:bg-white/5 data-[state=active]:border-primary/50 data-[state=active]:bg-primary/15 data-[state=active]:text-text"
              >
                {item.label}
              </Tabs.Trigger>
            ))}
          </Tabs.List>
          <div className="grid overflow-hidden rounded-2xl border border-white/10 bg-surface/40 lg:grid-cols-[1.55fr_1fr]">
            <div className="relative aspect-[1.56] overflow-hidden bg-[#12111a] lg:aspect-auto lg:min-h-[380px]">
              <picture>
                <source srcSet="/desk-illustrations.webp" type="image/webp" />
                <img
                  src="/desk-illustrations.png"
                  alt="Illustrated preview of the Mokaid desktop office, with team desks and meeting rooms"
                  width={1568}
                  height={1003}
                  loading="lazy"
                  decoding="async"
                  className="h-full w-full object-cover transition-transform duration-500 motion-reduce:transition-none"
                  style={{
                    transform: `scale(${view.zoom})`,
                    transformOrigin: `${view.x}% ${view.y}%`,
                  }}
                />
              </picture>
              <span className="absolute bottom-4 left-4 rounded-md bg-black/75 px-3 py-1.5 text-xs text-white">
                Desktop office · illustrated preview
              </span>
            </div>
            <div className="flex flex-col justify-center p-6 sm:p-9">
              {views.map((item) => (
                <Tabs.Content key={item.id} value={item.id} className="mk-focus-ring rounded-lg">
                  <h3 className="text-2xl font-semibold leading-tight tracking-tight sm:text-3xl">
                    {item.title}
                  </h3>
                  <p className="mt-4 text-base leading-relaxed text-text-secondary">{item.body}</p>
                </Tabs.Content>
              ))}
              <Link
                to="/download"
                className="mk-focus-ring mt-7 inline-flex min-h-11 w-fit items-center gap-2 rounded-md text-sm font-semibold text-primary-light"
              >
                Explore the download options <ArrowRight size={17} aria-hidden />
              </Link>
            </div>
          </div>
        </Tabs.Root>
      </div>
    </section>
  );
}
