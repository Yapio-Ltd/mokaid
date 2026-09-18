import { lazy, Suspense, useLayoutEffect, useRef, useState } from "react";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";

gsap.registerPlugin(ScrollTrigger);

// Marketing still ships the 3D roster even when the rest of the web app is
// account-only. Babylon stays in a lazy chunk, not in the landing entry.
const AgentPreview3D = lazy(() =>
  import("@/three/agent-preview").then((m) => ({ default: m.AgentPreview3D })),
);

const agents = [
  {
    id: "design",
    domain: "Design",
    name: "Ava",
    role: "AI Design Lead",
    title: "Interfaces & systems that feel inevitable",
    body: "She turns product briefs into polished UI: landings, dashboards, design systems, and ship-ready assets.",
    detail: "Hire her when brand and product need to look inevitable.",
    skills: ["UI / UX", "Design systems", "Visual craft"],
    cdnPath: "/assets3d/avatar_design.1c0dba698d81.glb",
    accent: "#c4b5fd",
    /** Avatar on this side; copy on the opposite */
    side: "left" as const,
  },
  {
    id: "legal",
    domain: "Legal",
    name: "Nora",
    role: "AI Legal Counsel",
    title: "Contracts, compliance, clear risk",
    body: "She reads agreements, flags exposure, and delivers actionable reviews without slowing the team down.",
    detail: "Hire her when every clause has to hold under pressure.",
    skills: ["Contracts", "Compliance", "Risk review"],
    cdnPath: "/assets3d/avatar_legal.859687268a64.glb",
    accent: "#a78bfa",
    side: "right" as const,
  },
  {
    id: "research",
    domain: "Research",
    name: "Dr. Kai",
    role: "AI Research Scientist",
    title: "Deep research, sharp synthesis",
    body: "He digests papers, markets, and weak signals into clear analyses: cited sources, usable conclusions.",
    detail: "Hire him when the answer has to be deep, not just fast.",
    skills: ["Deep research", "Market intel", "Synthesis"],
    cdnPath: "/assets3d/avatar_research.7c86fc428e9f.glb",
    accent: "#ddd6fe",
    side: "left" as const,
  },
  {
    id: "engineering",
    domain: "Engineering",
    name: "Alex",
    role: "AI Staff Engineer",
    title: "Code that ships clean",
    body: "He reviews PRs, debugs production, and turns specs into solid implementations without the drama.",
    detail: "Hire him when the stack has to stay sharp under load.",
    skills: ["Code review", "Debugging", "Architecture"],
    cdnPath: "/assets3d/avatar_developer.867211fc6b99.glb",
    accent: "#c4b5fd",
    side: "right" as const,
  },
] as const;

function AvatarFallback({ w, h }: { w: number; h: number }) {
  return (
    <div
      className="mk-agent-tour-canvas rounded-xl bg-surface/30"
      style={{ width: w, height: h }}
      aria-hidden
    />
  );
}

export function AgentTour() {
  const sectionRef = useRef<HTMLElement>(null);
  const glowRef = useRef<HTMLDivElement>(null);
  const activeRef = useRef(0);
  const [active, setActive] = useState(0);
  /** Mount WebGL only for visited stops (+ preload neighbor). */
  const [mounted, setMounted] = useState(() => new Set<number>([0, 1]));
  const [canvasSize, setCanvasSize] = useState({ w: 420, h: 560 });

  useLayoutEffect(() => {
    const measure = () => {
      const vw = window.innerWidth;
      const vh = window.innerHeight;
      if (vw < 400) {
        const w = Math.min(220, vw - 48);
        setCanvasSize({ w, h: Math.min(300, Math.round(vh * 0.36)) });
      } else if (vw < 640) {
        const w = Math.min(260, vw - 40);
        setCanvasSize({ w, h: Math.min(340, Math.round(vh * 0.4)) });
      } else if (vw < 900) {
        setCanvasSize({ w: 320, h: Math.min(420, Math.round(vh * 0.48)) });
      } else if (vw < 1024) {
        setCanvasSize({ w: 360, h: 480 });
      } else {
        setCanvasSize({ w: 440, h: 580 });
      }
    };
    measure();
    let timer = 0;
    const onResize = () => {
      window.clearTimeout(timer);
      timer = window.setTimeout(measure, 120);
    };
    window.addEventListener("resize", onResize);
    return () => {
      window.clearTimeout(timer);
      window.removeEventListener("resize", onResize);
    };
  }, []);

  useLayoutEffect(() => {
    const section = sectionRef.current;
    if (!section) return;

    const prefersReduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    const ctx = gsap.context(() => {
      const layouts = gsap.utils.toArray<HTMLElement>("[data-agent-layout]");
      const avatars = gsap.utils.toArray<HTMLElement>("[data-agent-stage]");
      const panels = gsap.utils.toArray<HTMLElement>("[data-agent-panel]");

      gsap.set(layouts, { opacity: 0, pointerEvents: "none" });
      gsap.set(layouts[0], { opacity: 1, pointerEvents: "auto" });
      gsap.set(avatars, { opacity: 0, scale: 0.94 });
      gsap.set(avatars[0], { opacity: 1, scale: 1 });

      const revealPanel = (el: HTMLElement, fromSide: "left" | "right") => {
        const xFrom = fromSide === "left" ? -40 : 40;
        const parts = el.querySelectorAll<HTMLElement>("[data-agent-reveal]");
        gsap.fromTo(
          parts,
          { opacity: 0, x: xFrom },
          {
            opacity: 1,
            x: 0,
            duration: 0.55,
            stagger: 0.08,
            ease: "power3.out",
            overwrite: "auto",
          },
        );
      };

      if (!prefersReduced) {
        const firstTextSide = agents[0].side === "left" ? "right" : "left";
        revealPanel(panels[0], firstTextSide);
      } else {
        gsap.set(panels[0].querySelectorAll("[data-agent-reveal]"), {
          opacity: 1,
          x: 0,
        });
      }

      const showStop = (i: number) => {
        if (activeRef.current === i) return;
        activeRef.current = i;
        setActive(i);
        setMounted((prev) => {
          const next = new Set(prev);
          next.add(i);
          if (i + 1 < agents.length) next.add(i + 1);
          return next;
        });

        layouts.forEach((el, idx) => {
          gsap.to(el, {
            opacity: idx === i ? 1 : 0,
            pointerEvents: idx === i ? "auto" : "none",
            duration: 0.35,
            overwrite: "auto",
          });
        });

        avatars.forEach((el, idx) => {
          gsap.to(el, {
            opacity: idx === i ? 1 : 0,
            scale: idx === i ? 1 : 0.94,
            duration: 0.45,
            ease: "power2.out",
            overwrite: "auto",
          });
        });

        panels.forEach((el, idx) => {
          if (idx === i) {
            if (!prefersReduced) {
              const textSide = agents[i].side === "left" ? "right" : "left";
              revealPanel(el, textSide);
            } else {
              gsap.set(el.querySelectorAll("[data-agent-reveal]"), {
                opacity: 1,
                x: 0,
              });
            }
          }
        });
      };

      if (prefersReduced) return;

      ScrollTrigger.create({
        trigger: section,
        start: "top top",
        end: "bottom bottom",
        pin: "[data-agent-pin]",
        scrub: 0.75,
        anticipatePin: 1,
        onUpdate: (self) => {
          const i = Math.min(agents.length - 1, Math.floor(self.progress * agents.length * 0.999));
          showStop(i);

          const local = self.progress * agents.length - i;
          if (glowRef.current) {
            const side = agents[i].side;
            gsap.set(glowRef.current, {
              opacity: 0.4 + local * 0.3,
              scale: 1 + local * 0.05,
              xPercent: side === "left" ? -18 : 18,
              force3D: true,
            });
          }
        },
      });

      // Recalculate pin spacers after lazy mount (avoids leftover black gaps).
      requestAnimationFrame(() => ScrollTrigger.refresh());
    }, section);

    return () => ctx.revert();
  }, []);

  const current = agents[active];

  return (
    <section
      ref={sectionRef}
      id="agents"
      className="mk-agent-tour relative z-10"
      style={{ ["--agent-stops" as string]: String(agents.length) }}
    >
      <div data-agent-pin className="mk-agent-tour-pin relative h-svh w-full">
        <div className="mk-agent-tour-shell">
          <div ref={glowRef} className="mk-agent-tour-glow" aria-hidden />

          <div className="mk-agent-tour-frame">
            {agents.map((agent, i) => {
              const textSide = agent.side === "left" ? "right" : "left";
              return (
                <div
                  key={agent.id}
                  data-agent-layout
                  className={`mk-agent-tour-layout is-avatar-${agent.side} ${active === i ? "is-active" : ""}`}
                  aria-hidden={active !== i}
                >
                  <div data-agent-stage className="mk-agent-tour-avatar">
                    <div className="mk-agent-tour-pedestal" aria-hidden />
                    {mounted.has(i) ? (
                      <Suspense fallback={<AvatarFallback w={canvasSize.w} h={canvasSize.h} />}>
                        <AgentPreview3D
                          name={agent.name}
                          color={agent.accent}
                          cdnPath={agent.cdnPath}
                          allowTint={false}
                          animation="idle"
                          active={active === i}
                          width={canvasSize.w}
                          height={canvasSize.h}
                          className="mk-agent-tour-canvas"
                        />
                      </Suspense>
                    ) : (
                      <AvatarFallback w={canvasSize.w} h={canvasSize.h} />
                    )}
                  </div>

                  <article data-agent-panel className={`mk-agent-tour-copy is-${textSide}`}>
                    <p className="mk-agent-tour-domain" data-agent-reveal>
                      {agent.domain}
                    </p>
                    <p className="mk-agent-tour-name" data-agent-reveal>
                      {agent.name}
                      <span> · {agent.role}</span>
                    </p>
                    <h2 className="mk-agent-tour-title" data-agent-reveal>
                      {agent.title}
                    </h2>
                    <p className="mk-agent-tour-body" data-agent-reveal>
                      {agent.body}
                    </p>
                    <ul className="mk-agent-tour-skills" data-agent-reveal>
                      {agent.skills.map((skill) => (
                        <li key={skill}>{skill}</li>
                      ))}
                    </ul>
                    <p className="mk-agent-tour-detail" data-agent-reveal>
                      {agent.detail}
                    </p>
                  </article>
                </div>
              );
            })}

            <div className="mk-agent-tour-dots" aria-hidden>
              {agents.map((agent, i) => (
                <span
                  key={agent.id}
                  className={`mk-agent-tour-dot ${active === i ? "is-active" : ""}`}
                />
              ))}
            </div>

            <div className="mk-agent-tour-rail" aria-hidden>
              <span
                className="mk-agent-tour-rail-fill"
                style={{ height: `${((active + 1) / agents.length) * 100}%` }}
              />
            </div>
          </div>

          <p className="mk-agent-tour-hint">
            {current.domain}
            <span className="mk-agent-tour-hint-sub">Sample agents</span>
          </p>
        </div>
      </div>
    </section>
  );
}
