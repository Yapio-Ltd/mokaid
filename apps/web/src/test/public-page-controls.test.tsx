import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import type { ComponentProps, ReactNode } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { AiEmployeeRolePage } from "@/pages/seo/ai-employee-role";
import { UseCaseDetailPage } from "@/pages/seo/use-case-detail";
import { CompareDetailPage } from "@/pages/seo/compare-detail";
import { BlogPostPage } from "@/pages/seo/blog-post";
import { PricingPage } from "@/pages/seo/pricing";
import { AiEmployeesIndexPage } from "@/pages/seo/ai-employees-index";
import { roles } from "@/data/seo/roles";
import { useCases } from "@/data/seo/useCases";
import { comparisons } from "@/data/seo/comparisons";

const state = vi.hoisted(() => ({ slug: "missing-page" }));
vi.mock("@tanstack/react-router", () => ({
  Link: ({ to, ...props }: ComponentProps<"a"> & { to: string }) => <a href={to} {...props} />,
  useParams: () => ({ slug: state.slug }),
}));
vi.mock("@/components/seo/marketing-layout", () => ({
  MarketingLayout: ({ children }: { children: ReactNode }) => <main>{children}</main>,
  Breadcrumbs: () => null,
  CtaBanner: () => null,
  FaqSection: () => null,
}));

afterEach(() => {
  cleanup();
  state.slug = "missing-page";
});

describe("public page navigation", () => {
  it.each([
    [AiEmployeeRolePage, "Role not found", "/ai-employees"],
    [UseCaseDetailPage, "Use case not found", "/use-cases"],
    [CompareDetailPage, "Comparison not found", "/compare"],
    [BlogPostPage, "Article not found", "/blog"],
  ] as const)(
    "provides a recovery link and noindex metadata on unknown detail pages",
    (Page, heading, destination) => {
      const { container } = render(<Page />);
      expect(screen.getByRole("heading", { level: 1, name: heading })).toBeInTheDocument();
      expect(screen.getByRole("link", { name: /Browse/ })).toHaveAttribute("href", destination);
      expect(container.querySelector("a button")).toBeNull();
      expect(document.querySelector('meta[name="robots"]')).toHaveAttribute(
        "content",
        "noindex, nofollow",
      );
    },
  );

  it.each([
    [AiEmployeesIndexPage, ""],
    [AiEmployeeRolePage, roles[0].slug],
    [UseCaseDetailPage, useCases[0].slug],
    [CompareDetailPage, comparisons[0].slug],
  ] as const)(
    "takes product calls to action to the desktop download without nested controls",
    (Page, slug) => {
      state.slug = slug;
      const { container } = render(<Page />);
      expect(screen.getByRole("link", { name: "Download Mokaid" })).toHaveAttribute(
        "href",
        "/download",
      );
      expect(container.querySelector("a button")).toBeNull();
      expect(document.querySelector('meta[name="robots"]')).toHaveAttribute(
        "content",
        "index, follow, max-image-preview:large",
      );
    },
  );

  it("shows the actual yearly totals and links paid plans to account plan selection", () => {
    const { container } = render(<PricingPage />);
    const monthly = screen.getByRole("button", { name: "Monthly" });
    const yearly = screen.getByRole("button", { name: "Yearly · save 17%" });
    expect(monthly).toHaveAttribute("aria-pressed", "true");
    fireEvent.click(yearly);
    expect(yearly).toHaveAttribute("aria-pressed", "true");
    expect(monthly).toHaveAttribute("aria-pressed", "false");
    expect(screen.getByText("$490 billed yearly")).toBeInTheDocument();
    expect(screen.getByText("$890 billed yearly")).toBeInTheDocument();
    expect(screen.getByText("$1490 billed yearly")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Choose Starter" })).toHaveAttribute(
      "href",
      "/account/plans",
    );
    expect(screen.getByRole("link", { name: "Start free" })).toHaveAttribute("href", "/signup");
    expect(container.querySelector("a button")).toBeNull();
    fireEvent.click(monthly);
    expect(screen.getAllByText("Billed monthly")).toHaveLength(3);
  });
});
