import { useEffect, useLayoutEffect, useRef, useState, type SyntheticEvent } from "react";
import { ArrowDown, ArrowRight, Check } from "lucide-react";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { cinematicStory, cueAtTime, cueOpacity, storyTimeAtProgress } from "@/data/cinematic-story";
import { createCinematicVideoController } from "@/lib/cinematic-video-controller";
import "./cinematic-story.css";

gsap.registerPlugin(ScrollTrigger);

const desktopQuery =
  "(min-width: 1024px) and (pointer: fine) and (prefers-reduced-motion: no-preference)";
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

/** Readable in the initial HTML, on mobile, with reduced motion, and without JS. */
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
  const lockedStatic = useRef(false);
  const [loadVideo, setLoadVideo] = useState(false);
  const [mode, setMode] = useState<StoryMode>("static");
  const [presentedTime, setPresentedTime] = useState(0);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    const section = sectionRef.current;
    const prerender = (window as Window & { __MOKAID_PRERENDER__?: boolean }).__MOKAID_PRERENDER__;
    if (!section || prerender || typeof window.matchMedia !== "function") return;
    const query = window.matchMedia(desktopQuery);
    // Never insert a source (or issue a video request) in the static modes.
    if (!query.matches) {
      lockedStatic.current = true;
      return;
    }
    let initialized = false;
    // WebKit can execute this module before the document's CSS has loaded.
    // Measuring then sees an unstyled, short hero and would lock a fresh visit
    // into the static layout. Wait for applicable styles, then measure once.
    const pendingStyles = new Set(
      Array.from(document.querySelectorAll<HTMLLinkElement>('link[rel~="stylesheet"]')).filter(
        (link) => !link.sheet && !link.disabled && window.matchMedia(link.media || "all").matches,
      ),
    );
    const initialize = () => {
      if (initialized) return;
      initialized = true;
      if (
        lockedStatic.current ||
        !query.matches ||
        section.getBoundingClientRect().top <= window.innerHeight
      ) {
        lockedStatic.current = true;
        return;
      }
      setLoadVideo(true);
      setMode("loading");
    };
    const onStyleSettled = (event: Event) => {
      pendingStyles.delete(event.currentTarget as HTMLLinkElement);
      if (pendingStyles.size === 0) initialize();
    };
    const styleLinks = Array.from(pendingStyles);
    for (const link of styleLinks) {
      link.addEventListener("load", onStyleSettled);
      link.addEventListener("error", onStyleSettled);
    }
    // Also handles a stylesheet that was replaced while the page was loading.
    window.addEventListener("load", initialize, { once: true });
    if (pendingStyles.size === 0 || document.readyState === "complete") initialize();
    const onChange = () => {
      if (query.matches) return;
      lockedStatic.current = true;
      setMode("static");
      setLoadVideo(false);
    };
    query.addEventListener("change", onChange);
    return () => {
      initialized = true;
      window.removeEventListener("load", initialize);
      query.removeEventListener("change", onChange);
      for (const link of styleLinks) {
        link.removeEventListener("load", onStyleSettled);
        link.removeEventListener("error", onStyleSettled);
      }
    };
  }, []);

  useEffect(() => {
    const video = videoRef.current;
    const section = sectionRef.current;
    if (!loadVideo || !video || !section || lockedStatic.current) return;
    let enhanced = false;
    let disposed = false;
    let timeout = 0;
    const retainStatic = () => {
      if (disposed) return;
      lockedStatic.current = true;
      setMode("static");
      setLoadVideo(false);
    };
    const beforeEntry = () => section.getBoundingClientRect().top > window.innerHeight;
    const onScroll = () => {
      if (!enhanced && !beforeEntry()) retainStatic();
    };
    const controller = createCinematicVideoController(video, {
      duration: cinematicStory.duration,
      fps: cinematicStory.fps,
      onReady() {
        window.clearTimeout(timeout);
        if (disposed || lockedStatic.current) return;
        if (!beforeEntry()) {
          retainStatic();
          return;
        }
        // Change the section's height only while it is still below the viewport.
        enhanced = true;
        setMode("cinematic");
      },
      onPresented(time) {
        if (!disposed) setPresentedTime(time);
      },
      onError() {
        window.clearTimeout(timeout);
        if (enhanced) setFailed(true);
        else retainStatic();
      },
    });
    controllerRef.current = controller;
    window.addEventListener("scroll", onScroll, { passive: true });
    timeout = window.setTimeout(retainStatic, 12_000);
    video.src = cinematicStory.video;
    video.load();
    return () => {
      disposed = true;
      window.clearTimeout(timeout);
      window.removeEventListener("scroll", onScroll);
      controller.dispose();
      controllerRef.current = undefined;
      video.removeAttribute("src");
      video.load();
    };
  }, [loadVideo]);

  useLayoutEffect(() => {
    const section = sectionRef.current;
    const stage = stageRef.current;
    if (mode !== "cinematic" || !section || !stage) return;
    const trigger = ScrollTrigger.create({
      trigger: section,
      start: "top top",
      end: "bottom bottom",
      scrub: true,
      invalidateOnRefresh: true,
      onUpdate(self) {
        controllerRef.current?.request(storyTimeAtProgress(self.progress));
      },
      onRefresh(self) {
        controllerRef.current?.request(storyTimeAtProgress(self.progress));
      },
    });
    const tick = (now: number) => {
      if (!document.hidden) controllerRef.current?.tick(now);
    };
    const onVisibilityChange = () => {
      if (document.hidden) controllerRef.current?.suspend();
    };
    // Subscribe to the same ticker as useSmoothScroll; there is no local RAF.
    gsap.ticker.add(tick);
    document.addEventListener("visibilitychange", onVisibilityChange);
    ScrollTrigger.refresh();
    return () => {
      gsap.ticker.remove(tick);
      document.removeEventListener("visibilitychange", onVisibilityChange);
      trigger.kill();
      ScrollTrigger.refresh();
    };
  }, [mode]);

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
      aria-label="Discover the Mokaid AI office"
    >
      <StaticStory />
      {loadVideo && (
        <div
          ref={stageRef}
          className="mk-cinema-stage"
          data-presented-time={presentedTime.toFixed(3)}
          aria-hidden={!enhanced}
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
              tabIndex={enhanced ? 0 : -1}
            >
              Skip the tour <ArrowDown size={12} aria-hidden="true" />
            </a>
          </div>
          {!failed && cue && (
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
              <h2>Your AI employees are already at work.</h2>
              <p>Meet your team in Mokaid Desktop.</p>
              <TeamLink />
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
