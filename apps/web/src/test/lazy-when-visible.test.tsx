import { cleanup, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { LazyWhenVisible } from "@/components/landing/lazy-when-visible";

afterEach(() => {
  cleanup();
  window.location.hash = "";
  vi.restoreAllMocks();
});

describe("LazyWhenVisible", () => {
  it("keeps children unmounted until near the viewport", () => {
    const observe = vi.fn();
    vi.stubGlobal(
      "IntersectionObserver",
      vi.fn(function (this: IntersectionObserver) {
        this.observe = observe;
        this.disconnect = vi.fn();
        this.unobserve = vi.fn();
        this.takeRecords = vi.fn(() => []);
        this.root = null;
        this.rootMargin = "";
        this.thresholds = [];
      }),
    );

    render(
      <LazyWhenVisible>
        <div>Heavy section</div>
      </LazyWhenVisible>,
    );

    expect(screen.queryByText("Heavy section")).toBeNull();
    expect(observe).toHaveBeenCalled();
  });

  it("mounts immediately when the eager hash is already active", async () => {
    window.location.hash = "#marketplace";
    const scrollIntoView = vi.fn();
    vi.spyOn(document, "getElementById").mockReturnValue({
      scrollIntoView,
    } as unknown as HTMLElement);

    render(
      <LazyWhenVisible eagerHash="#marketplace">
        <section id="marketplace">Marketplace body</section>
      </LazyWhenVisible>,
    );

    expect(screen.getByText("Marketplace body")).toBeInTheDocument();
    await waitFor(() => expect(scrollIntoView).toHaveBeenCalled());
  });
});
