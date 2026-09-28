import manifest from "./cinematic-story.json";
import type { FramePack } from "@/lib/cinematic-frame-controller";

export interface StoryWaypoint {
  progress: number;
  time: number;
}

export interface StoryCue {
  id: string;
  start: number;
  end: number;
  text: string;
  secondary?: string;
  position: "left" | "center";
  cta?: boolean;
}

export interface StoryFramePack extends FramePack {
  bytes?: number;
}

export interface CinematicStoryManifest {
  version: number;
  duration: number;
  fps: number;
  logoAt: number;
  cta: { text: string; href: string };
  frames: {
    digest: string;
    quality: number | { desktop: number; mobile: number };
    desktop: StoryFramePack;
    mobile: StoryFramePack;
  };
  poster: string;
  stills: { entry: string; work: string; life: string };
  scrollMap: StoryWaypoint[];
  scenes: { id: string; start: number; end: number; label: string }[];
  cues: StoryCue[];
  notifications: { id: string; time: number; text: string }[];
}

/** Shared with the film export pipeline; times refer to the 74-second master. */
export const cinematicStory = manifest as CinematicStoryManifest;

/** Piecewise-linear so every authored scroll beat is exact in both directions. */
export function storyTimeAtProgress(progress: number): number {
  const points = cinematicStory.scrollMap;
  const clamped = Math.max(0, Math.min(1, Number.isFinite(progress) ? progress : 0));
  const next = points.findIndex((point) => point.progress >= clamped);
  if (next <= 0) return points[0].time;
  const before = points[next - 1];
  const after = points[next];
  const local = (clamped - before.progress) / (after.progress - before.progress);
  return before.time + local * (after.time - before.time);
}

export function cueAtTime(time: number): StoryCue | undefined {
  return cinematicStory.cues.find(
    (cue) =>
      time >= cue.start &&
      (time < cue.end || (cue.end === cinematicStory.duration && time === cue.end)),
  );
}

/** No exit fade on the last frame: the completed-work CTA stays readable. */
export function cueOpacity(cue: StoryCue, time: number): number {
  const fadeIn = Math.min(1, Math.max(0, (time - cue.start) / 0.5));
  const fadeOut = cue.end === cinematicStory.duration ? 1 : Math.min(1, (cue.end - time) / 0.45);
  return Math.max(0, Math.min(fadeIn, fadeOut));
}
