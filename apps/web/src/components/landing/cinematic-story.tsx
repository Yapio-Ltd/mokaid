import { useEffect, useLayoutEffect, useRef, useState, type SyntheticEvent } from "react";
import { ArrowDown, ArrowRight, Check } from "lucide-react";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { cinematicStory, cueAtTime, cueOpacity, storyTimeAtProgress } from "@/data/cinematic-story";
import {
  createCinematicFrameController,
  desktopHighPack,
  MOBILE_FRAME_QUERY,
  selectFramePack,
} from "@/lib/cinematic-frame-controller";
import { readNavigatorConnection, resolveDesktopTier } from "@/lib/cinematic-network-tier";
import "./cinematic-story.css";

gsap.registerPlugin(ScrollTrigger);

const motionQuery = "(prefers-reduced-motion: no-preference)";
type StoryMode = "static" | "loading" | "cinematic";

function fallbackIllustration(event: SyntheticEvent<HTMLImageElement>) {
  const image = event.currentTarget;
  if (image.dataset.fallback) return;
  image.dataset.fallback = "true";
  image.src = "/desk-illustrations.webp";
}

function TeamLink({ className = "" }: { className?: string }) {
  return (
    <a className={`mk-cinema-cta mk-focus-ring ${className}`} href={cinematicStory.cta.href}>
      {cinematicStory.cta.text} <ArrowRight size={17} aria-hidden="true" />
    </a>
  );
}

/** Readable in the initial HTML, with reduced motion, and without JavaScript. */
function StaticStory() {
  return (
    <div className="mk-cinema-static">
      <header className="mk-cinema-static-intro">
        <span className="mk-cinema-eyebrow">A world behind your screen</span>
        <h2>Your AI team is closer than you think.</h2>
        <p>A complete AI team, inside your desktop.</p>
      </header>
      <div className="mk-cinema-moments">
        <article className="mk-cinema-moment">
          <div className="mk-cinema-still">
            <img
              src={cinematicStory.stills.entry}
              width={1920}
              height={1080}
              loading="lazy"
              decoding="async"
              onError={fallbackIllustration}
              alt="The Mokaid AI office, illuminated by violet pathways and warm desk lights."
            />
          </div>
          <div className="mk-cinema-moment-copy">
            <span className="mk-cinema-eyebrow">01 / Enter Mokaid</span>
            <h3>Enter your AI office.</h3>
            <p>Give every specialist a role, tools and context.</p>
          </div>
        </article>
        <article className="mk-cinema-moment">
          <div className="mk-cinema-still">
            <img
              src={cinematicStory.stills.work}
              width={1920}
              height={1080}
              loading="lazy"
              decoding="async"
              onError={fallbackIllustration}
              alt="AI employees collaborating on a task in the Mokaid office."
            />
          </div>
          <div className="mk-cinema-moment-copy">
            <span className="mk-cinema-eyebrow">02 / Watch them work</span>
            <h3>One task becomes a workflow.</h3>
            <p>
              Specialists coordinate to deliver the result. Assign a goal. Follow their progress.
            </p>
          </div>
        </article>
        <article className="mk-cinema-moment">
          <div className="mk-cinema-still">
            <img
              src={cinematicStory.stills.life}
              width={1920}
              height={1080}
              loading="lazy"
              decoding="async"
              onError={fallbackIllustration}
              alt="AI teammates sharing a coffee break in the same Mokaid office."
            />
          </div>
          <div className="mk-cinema-moment-copy">
            <span className="mk-cinema-eyebrow">03 / Meet your teammates</span>
            <h3>Even AI needs a coffee break.</h3>
            <p>Fortunately, they don't need payroll.</p>
          </div>
        </article>
      </div>
      <div className="mk-cinema-static-payoff mk-final-cta">
        <span className="mk-cinema-eyebrow">Connected tools. Completed work.</span>
        <h2>Your AI employees are already at work.</h2>
        <TeamLink />
        <p>Mokaid Desktop · macOS &amp; Windows</p>
      </div>
    </div>
  );
}

export function CinematicStory() {
  const sectionRef = useRef<HTMLElement>(null);
  const stageRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const controllerRef = useRef<ReturnType<typeof createCinematicFrameController>>();
  const requestedTimeRef = useRef(0);
  const [loadFrames, setLoadFrames] = useState(false);
  const [mode, setMode] = useState<StoryMode>("static");
  const [presentedTime, setPresentedTime] = useState(0);
  const [failed, setFailed] = useState(false);
  const [attempt, setAttempt] = useState(0);
  const [loadProgress, setLoadProgress] = useState(0);

  useLayoutEffect(() => {
    const prerender = (window as Window & { __MOKAID_PRERENDER__?: boolean }).__MOKAID_PRERENDER__;
    if (prerender || typeof window.matchMedia !== "function") return;
    const query = window.matchMedia(motionQuery);
    const configure = () => {
      setLoadFrames(query.matches);
      setMode(query.matches ? "loading" : "static");
      setFailed(false);
      setPresentedTime(0);
      setLoadProgress(0);
    };
    configure();
    query.addEventListener("change", configure);
    return () => query.removeEventListener("change", configure);
  }, []);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!loadFrames || !canvas) return;
    let disposed = false;
    const mobileQuery = window.matchMedia(MOBILE_FRAME_QUERY);
    const isMobile = mobileQuery.matches;
    const pack = selectFramePack(cinematicStory.frames, mobileQuery);
    const high = !isMobile ? desktopHighPack(cinematicStory.frames) : undefined;
    const hasNetInfo = Boolean(readNavigatorConnection());
    const tier = !isMobile
      ? resolveDesktopTier({
          allowMissingApiUpgrade: true,
        })
      : "base";
    const controller = createCinematicFrameController({
      pack,
      upgradePack: high,
      upgradeEnabled: Boolean(high && tier === "high"),
      // Safari / missing NetInfo: densify after ~1s idle once base is ready.
      upgradeDelayMs: !isMobile && !hasNetInfo && tier === "high" ? 1000 : 0,
      duration: cinematicStory.duration,
      canvas,
      onReady() {
        if (!disposed) setMode("cinematic");
      },
      onPresented(time) {
        if (!disposed) setPresentedTime(time);
      },
      onError() {
        if (!disposed) setFailed(true);
      },
      onProgress(loaded, total) {
        if (!disposed) setLoadProgress(total > 0 ? loaded / total : 0);
      },
    });
    controllerRef.current = controller;
    controller.request(requestedTimeRef.current);
    const onResize = () => controller.redraw();
    window.addEventListener("resize", onResize);
    return () => {
      disposed = true;
      window.removeEventListener("resize", onResize);
      controller.dispose();
      controllerRef.current = undefined;
    };
  }, [loadFrames, attempt]);

  useLayoutEffect(() => {
    const section = sectionRef.current;
    const stage = stageRef.current;
    if (!loadFrames || !section || !stage) return;
    const syncProgress = (progress: number) => {
      requestedTimeRef.current = storyTimeAtProgress(progress);
      controllerRef.current?.request(requestedTimeRef.current);
    };
    const trigger = ScrollTrigger.create({
      trigger: section,
      start: "top top",
      end: "bottom bottom",
      scrub: true,
      invalidateOnRefresh: true,
      onUpdate(self) {
        syncProgress(self.progress);
      },
      onRefresh(self) {
        syncProgress(self.progress);
      },
    });
    const tick = (now: number) => {
      if (!document.hidden) controllerRef.current?.tick(now);
    };
    const refresh = () => {
      ScrollTrigger.refresh();
      syncProgress(trigger.progress);
      controllerRef.current?.redraw();
    };
    const onVisibilityChange = () => {
      if (document.hidden) controllerRef.current?.suspend();
      else refresh();
    };
    gsap.ticker.add(tick);
    document.addEventListener("visibilitychange", onVisibilityChange);
    window.addEventListener("pageshow", refresh);
    window.addEventListener("load", refresh);
    refresh();
    return () => {
      gsap.ticker.remove(tick);
      document.removeEventListener("visibilitychange", onVisibilityChange);
      window.removeEventListener("pageshow", refresh);
      window.removeEventListener("load", refresh);
      trigger.kill();
      ScrollTrigger.refresh();
    };
  }, [loadFrames]);

  const retry = () => {
    setFailed(false);
    setMode("loading");
    setPresentedTime(0);
    setLoadProgress(0);
    setAttempt((previous) => previous + 1);
  };

  const cue = cueAtTime(presentedTime);
  const scene = cinematicStory.scenes.find(
    (item) => presentedTime >= item.start && presentedTime < item.end,
  );
  const notificationCount = cinematicStory.notifications.filter(
    (item) => presentedTime >= item.time,
  ).length;
  const enhanced = mode === "cinematic";

  return (
    <section
      id="product"
      ref={sectionRef}
      className="mk-cinematic-story"
      data-mode={mode}
      data-frames-ready={enhanced && !failed}
      data-video-ready={enhanced && !failed}
      aria-label="Discover the Mokaid AI office"
    >
      <StaticStory />
      {loadFrames && (
        <div
          ref={stageRef}
          className="mk-cinema-stage"
          data-presented-time={presentedTime.toFixed(3)}
          aria-hidden={!loadFrames}
        >
          <img
            className="mk-cinema-poster"
            src={cinematicStory.poster}
            alt=""
            onError={fallbackIllustration}
            aria-hidden="true"
          />
          <canvas ref={canvasRef} className="mk-cinema-video mk-cinema-canvas" aria-hidden="true" />
          <div className="mk-cinema-shade" aria-hidden="true" />
          <div className="mk-cinema-topline">
            <span className="mk-cinema-eyebrow">Inside Mokaid</span>
            <a
              href="#cinematic-story-end"
              className="mk-cinema-skip mk-focus-ring"
              tabIndex={loadFrames ? 0 : -1}
            >
              Skip the tour <ArrowDown size={12} aria-hidden="true" />
            </a>
          </div>
          {!failed && !enhanced && (
            <div className="mk-cinema-loading">
              <p role="status">
                {loadProgress > 0
                  ? `Loading the tour… ${Math.round(loadProgress * 100)}%`
                  : "Loading the tour…"}
              </p>
            </div>
          )}
          {!failed && enhanced && cue && (
            <div
              className={`mk-cinema-cue mk-cinema-cue--${cue.position}${cue.cta ? " mk-final-cta" : ""}`}
              key={cue.id}
              style={{ "--cue-opacity": cueOpacity(cue, presentedTime) } as React.CSSProperties}
            >
              <h2>{cue.text}</h2>
              {cue.secondary && <p>{cue.secondary}</p>}
              {cue.cta && <TeamLink />}
            </div>
          )}
          {!failed && notificationCount > 0 && (
            <div className="mk-cinema-notifications" aria-label="Examples of completed tasks">
              {cinematicStory.notifications.slice(0, notificationCount).map((notification) => (
                <div
                  className="mk-cinema-notification"
                  key={notification.id}
                  style={
                    {
                      "--notification-progress": Math.min(
                        1,
                        (presentedTime - notification.time) / 0.35,
                      ),
                    } as React.CSSProperties
                  }
                >
                  <span className="mk-cinema-check">
                    <Check size={12} strokeWidth={2.5} aria-hidden="true" />
                  </span>
                  <span>{notification.text}</span>
                </div>
              ))}
            </div>
          )}
          {!failed && presentedTime >= cinematicStory.logoAt && (
            <img
              className="mk-cinema-final-logo"
              src="/branding/logo-without-bg.webp"
              width={64}
              height={64}
              alt="Mokaid"
            />
          )}
          {failed && (
            <div className="mk-cinema-cue mk-cinema-cue--left mk-cinema-recovery mk-final-cta">
              <h2>The tour couldn’t load.</h2>
              <p>Try again to resume from your scroll position.</p>
              <button type="button" className="mk-cinema-cta mk-focus-ring" onClick={retry}>
                Retry the tour
              </button>
              <a href="#cinematic-story-end" className="mk-cinema-recovery-link mk-focus-ring">
                Continue exploring <ArrowDown size={14} aria-hidden="true" />
              </a>
            </div>
          )}
          <div className="mk-cinema-bottomline" aria-hidden="true">
            <span>{scene?.label ?? "Already done"}</span>
            <div className="mk-cinema-progress">
              <span style={{ transform: `scaleX(${presentedTime / cinematicStory.duration})` }} />
            </div>
            <span>Scroll to explore</span>
          </div>
        </div>
      )}
      <div id="cinematic-story-end" className="mk-cinema-end" />
      <noscript>
        <style>{`.mk-cinematic-story{min-height:0!important}.mk-cinematic-story .mk-cinema-static{display:block!important}.mk-cinema-stage{display:none!important}`}</style>
      </noscript>
    </section>
  );
}
