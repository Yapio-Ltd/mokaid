import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { MarketplaceShowcase } from "@/components/landing/marketplace-showcase";

vi.mock("@tanstack/react-router", () => ({
  Link: ({ to, children, ...props }: { to: string; children?: unknown } & Record<string, unknown>) => (
    <a href={typeof to === "string" ? to : "/"} {...props}>
      {children as never}
    </a>
  ),
}));

afterEach(() => cleanup());

describe("MarketplaceShowcase", () => {
  it("explains sell, rent, and the level 10 lock", () => {
    render(<MarketplaceShowcase />);

    expect(document.getElementById("marketplace")).toBeTruthy();
    expect(screen.getByRole("heading", { name: /Put trained agents to work/i })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Sell copies" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Rent monthly or fixed" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Level 10 required" })).toBeInTheDocument();
    expect(screen.getByText(/impossible to put an agent online before level 10/i)).toBeInTheDocument();
    expect(screen.getByText(/Mokaid takes 15%/i)).toBeInTheDocument();
    expect(screen.getByAltText(/level 10 research agent/i)).toHaveAttribute(
      "src",
      "/landing/marketplace/card-listing.svg",
    );
  });
});
