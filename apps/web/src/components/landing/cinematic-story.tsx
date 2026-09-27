import { useEffect, useLayoutEffect, useRef, useState, type SyntheticEvent } from "react";
import { ArrowDown, ArrowRight, Check } from "lucide-react";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { cinematicStory, cueAtTime, cueOpacity, storyTimeAtProgress } from "@/data/cinematic-story";
import { createCinematicVideoController } from "@/lib/cinematic-video-controller";
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
  const videoRef = useRef<HTMLVideoElement>(null);
  const controllerRef = useRef<ReturnType<typeof createCinematicVideoController>>();
  const requestedTimeRef = useRef(0);
  const [loadVideo, setLoadVideo] = useState(false);
  const [mode, setMode] = useState<StoryMode>("static");
  const [presentedTime, setPresentedTime] = useState(0);
  const [failed, setFailed] = useState(false);
  const [slowLoading, setSlowLoading] = useState(false);
  const [attempt, setAttempt] = useState(0);

  useLayoutEffect(() => {
    const prerender = (window as Window & { __MOKAID_PRERENDER__?: boolean }).__MOKAID_PRERENDER__;
    if (prerender || typeof window.matchMedia !== "function") return;
    const query = window.matchMedia(motionQuery);
    const configure = () => {
      // Reserve the complete scroll track before paint, including restored visits.
      // Device size, pointer type and loading speed never disable the experience.
      setLoadVideo(query.matches);
      setMode(query.matches ? "loading" : "static");
      setFailed(false);
      setPresentedTime(0);
    };
    configure();
    query.addEventListener("change", configure);
    return () => query.removeEventListener("change", configure);
  }, []);

  useEffect(() => {
    const video = videoRef.current;
    if (!loadVideo || !video) return;
    let disposed = false;
    setSlowLoading(false);
    // Offer recovery for a stalled request without cancelling a slow download.
    const loadingTimer = window.setTimeout(() => setSlowLoading(true), 12_000);
    const controller = createCinematicVideoController(video, {
      duration: cinematicStory.duration,
      fps: cinematicStory.fps,
      onReady() {
        window.clearTimeout(loadingTimer);
        if (!disposed) setMode("cinematic");
      },
      onPresented(time) {
        if (!disposed) setPresentedTime(time);
      },
      onError() {
        window.clearTimeout(loadingTimer);
        // Keep the track stable and allow retrying at the current scroll position.
        if (!disposed) setFailed(true);
      },
    });
    controllerRef.current = controller;
    controller.request(requestedTimeRef.current);
    video.src = cinematicStory.video;
    video.load();
    return () => {
      disposed = true;
      window.clearTimeout(loadingTimer);
      controller.dispose();
      controllerRef.current = undefined;
      video.removeAttribute("src");
      video.load();
    };
  }, [loadVideo, attempt]);

  useLayoutEffect(() => {
    const section = sectionRef.current;
    const stage = stageRef.current;
    if (!loadVideo || !section || !stage) return;
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
    };
    const onVisibilityChange = () => {
      if (document.hidden) controllerRef.current?.suspend();
      else refresh();
    };
    // Native touch scrolling and Lenis use the same ScrollTrigger/ticker lifecycle.
    // Start while loading so delayed media can catch up to any restored position.
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
  }, [loadVideo]);

  const retry = () => {
    setFailed(false);
    setSlowLoading(false);
    setMode("loading");
    setPresentedTime(0);
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
      data-video-ready={enhanced && !failed}
      aria-label="Discover the Mokaid AI office"
    >
      <StaticStory />
      {loadVideo && (
        <div
          ref={stageRef}
          className="mk-cinema-stage"
          data-presented-time={presentedTime.toFixed(3)}
          aria-hidden={!loadVideo}
        >
          <img
            className="mk-cinema-poster"
            src={cinematicStory.poster}
            alt=""
            onError={fallbackIllustration}
            aria-hidden="true"
          />
          <video
            ref={videoRef}
            className="mk-cinema-video"
            muted
            playsInline
            preload="auto"
            aria-hidden="true"
            tabIndex={-1}
            disablePictureInPicture
          />
          <div className="mk-cinema-shade" aria-hidden="true" />
          <div className="mk-cinema-topline">
            <span className="mk-cinema-eyebrow">Inside Mokaid</span>
            <a
              href="#cinematic-story-end"
              className="mk-cinema-skip mk-focus-ring"
              tabIndex={loadVideo ? 0 : -1}
            >
              Skip the tour <ArrowDown size={12} aria-hidden="true" />
            </a>
          </div>
          {!failed && !enhanced && (
            <div className="mk-cinema-loading">
              <p role="status">
                {slowLoading ? "The tour is taking longer to load." : "Loading the tour…"}
              </p>
              {slowLoading && (
                <button type="button" className="mk-cinema-cta mk-focus-ring" onClick={retry}>
                  Retry the tour
                </button>
              )}
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
