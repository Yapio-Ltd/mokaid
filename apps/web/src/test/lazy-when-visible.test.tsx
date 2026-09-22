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
      class {
        observe = observe;
        unobserve = vi.fn();
        disconnect = vi.fn();
        takeRecords = () => [];
      },
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
