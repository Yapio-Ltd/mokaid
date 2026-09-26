import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { CinematicStory } from "@/components/landing/cinematic-story";
import { cinematicStory } from "@/data/cinematic-story";

const mocks = vi.hoisted(() => ({
  tickerAdd: vi.fn(),
  tickerRemove: vi.fn(),
  triggerKill: vi.fn(),
  refresh: vi.fn(),
}));
vi.mock("gsap", () => ({
  default: {
    registerPlugin: vi.fn(),
    ticker: { add: mocks.tickerAdd, remove: mocks.tickerRemove },
  },
}));
vi.mock("gsap/ScrollTrigger", () => ({
  ScrollTrigger: { create: () => ({ kill: mocks.triggerKill }), refresh: mocks.refresh },
}));

let top = 2000;
let readyState = 0;
let eligible = true;
let query: EventTarget & { matches: boolean; media: string };

beforeEach(() => {
  top = 2000;
  readyState = 0;
  eligible = true;
  query = Object.assign(new EventTarget(), { matches: true, media: "desktop" });
  vi.stubGlobal(
    "matchMedia",
    vi.fn(() => {
      query.matches = eligible;
      return query;
    }),
  );
  vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(() => ({
    top,
    bottom: top + 1500,
    left: 0,
    right: 1440,
    width: 1440,
    height: 1500,
    x: 0,
    y: top,
    toJSON: () => ({}),
  }));
  vi.spyOn(HTMLMediaElement.prototype, "load").mockImplementation(() => undefined);
  vi.spyOn(HTMLMediaElement.prototype, "pause").mockImplementation(() => undefined);
  vi.spyOn(HTMLMediaElement.prototype, "duration", "get").mockReturnValue(74);
  vi.spyOn(HTMLMediaElement.prototype, "seekable", "get").mockReturnValue({
    length: 1,
    start: () => 0,
    end: () => 74,
  });
  vi.spyOn(HTMLMediaElement.prototype, "readyState", "get").mockImplementation(() => readyState);
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});

describe("cinematic story progressive enhancement", () => {
  it("never attaches a video source in mobile/reduced-motion mode", () => {
    eligible = false;
    const { container } = render(<CinematicStory />);
    expect(container.querySelector("video")).toBeNull();
    expect(screen.getAllByRole("img")).toHaveLength(3);
    expect(screen.getByRole("link", { name: /Build your team/ })).toHaveAttribute(
      "href",
      "/download",
    );
    expect(screen.getByRole("heading", { name: "Enter your AI office." })).toBeVisible();
  });

  it("keeps prerendered content static, semantic and source-free", () => {
    vi.stubGlobal("__MOKAID_PRERENDER__", true);
    const { container } = render(<CinematicStory />);
    expect(container.querySelector("video")).toBeNull();
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "static");
    expect(
      screen.getByRole("heading", { name: "Your AI employees are already at work." }),
    ).toBeVisible();
  });

  it("only promotes the ready film while the section is still below the viewport", () => {
    const { container, unmount } = render(<CinematicStory />);
    const video = container.querySelector("video")!;
    expect(video).toHaveAttribute("src", cinematicStory.video);
    expect(video.muted).toBe(true);
    expect(video).toHaveAttribute("playsinline");
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "loading");
    readyState = 2;
    fireEvent.loadedData(video);
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "cinematic");
    expect(mocks.tickerAdd).toHaveBeenCalledOnce();
    unmount();
    expect(mocks.tickerRemove).toHaveBeenCalledOnce();
    expect(mocks.triggerKill).toHaveBeenCalledOnce();
  });

  it("locks the static layout if the visitor enters before the film is ready", () => {
    const { container } = render(<CinematicStory />);
    const video = container.querySelector("video")!;
    top = 200;
    fireEvent.scroll(window);
    expect(container.querySelector("video")).toBeNull();
    expect(video).not.toHaveAttribute("src");
    readyState = 2;
    fireEvent.loadedData(video);
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "static");
    expect(mocks.tickerAdd).not.toHaveBeenCalled();
  });

  it("does not begin loading on a restored mid-page visit", () => {
    top = -200;
    const { container } = render(<CinematicStory />);
    expect(container.querySelector("video")).toBeNull();
  });

  it("waits for pending CSS before measuring whether the visitor has entered", () => {
    vi.spyOn(document, "readyState", "get").mockReturnValue("interactive");
    const stylesheet = document.createElement("link");
    stylesheet.rel = "stylesheet";
    stylesheet.href = "/pending-layout.css";
    document.head.append(stylesheet);
    try {
      top = 400;
      const { container } = render(<CinematicStory />);
      expect(container.querySelector("video")).toBeNull();
      top = 2000;
      fireEvent.load(stylesheet);
      expect(container.querySelector("video")).toHaveAttribute("src", cinematicStory.video);
      expect(container.querySelector("#product")).toHaveAttribute("data-mode", "loading");
    } finally {
      stylesheet.remove();
    }
  });

  it("stays static if the visitor enters while initial CSS is pending", () => {
    vi.spyOn(document, "readyState", "get").mockReturnValue("interactive");
    const stylesheet = document.createElement("link");
    stylesheet.rel = "stylesheet";
    stylesheet.href = "/pending-layout.css";
    document.head.append(stylesheet);
    try {
      const { container } = render(<CinematicStory />);
      top = 200;
      fireEvent.load(stylesheet);
      expect(container.querySelector("video")).toBeNull();
      expect(container.querySelector("#product")).toHaveAttribute("data-mode", "static");
    } finally {
      stylesheet.remove();
    }
  });

  it("returns to illustrated content on loading failure or a reduced-motion change", () => {
    const { container, unmount } = render(<CinematicStory />);
    fireEvent.error(container.querySelector("video")!);
    expect(container.querySelector("video")).toBeNull();
    unmount();
    const next = render(<CinematicStory />);
    readyState = 2;
    fireEvent.loadedData(next.container.querySelector("video")!);
    act(() => {
      query.matches = false;
      query.dispatchEvent(new Event("change"));
    });
    expect(next.container.querySelector("video")).toBeNull();
    expect(next.container.querySelector("#product")).toHaveAttribute("data-mode", "static");
  });
});
