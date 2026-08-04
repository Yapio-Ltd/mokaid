import { describe, expect, it, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import {
  SiteDeliveryChoice,
  isSiteDeliveryChoice,
} from "@/components/approvals/site-delivery-choice";

describe("SiteDeliveryChoice", () => {
  it("detects site_delivery_choice payload", () => {
    expect(isSiteDeliveryChoice({ kind: "site_delivery_choice" })).toBe(true);
    expect(isSiteDeliveryChoice({ kind: "other" })).toBe(false);
  });

  it("renders two cards and reports the chosen delivery", () => {
    const onChoose = vi.fn();
    render(
      <SiteDeliveryChoice
        payload={{
          kind: "site_delivery_choice",
          recommended: "webapp",
          reason: "Boutique → codebase recommandé.",
          options: [
            { id: "html", label: "Simple vitrine HTML", blurb: "HTML" },
            {
              id: "webapp",
              label: "Codebase complet (React + Next.js + TypeScript)",
              blurb: "Next",
            },
          ],
        }}
        onChoose={onChoose}
      />,
    );
    expect(screen.getByText(/Simple vitrine HTML/i)).toBeInTheDocument();
    expect(screen.getByText(/Codebase complet/i)).toBeInTheDocument();
    fireEvent.click(screen.getByText(/Simple vitrine HTML/i));
    expect(onChoose).toHaveBeenCalledWith("html");
  });
});
