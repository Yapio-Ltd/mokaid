import { cleanup, render, screen, waitFor } from "@testing-library/react";
import type { ComponentProps } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DownloadPage, desktopReleaseSchema } from "@/pages/download";

vi.mock("@tanstack/react-router", () => ({
  Link: ({ to, ...props }: ComponentProps<"a"> & { to: string }) => <a href={to} {...props} />,
}));
vi.mock("@/lib/use-seo", () => ({ useSeo: () => undefined }));

const release = {
  schemaVersion: 1,
  channel: "stable",
  version: "1.2.3",
  publishedAt: "2026-09-13T11:00:00+00:00",
  releaseNotesUrl: "https://github.com/Yapio-Ltd/mokaid/releases/tag/desktop-v1.2.3",
  downloads: {
    "macos-arm64": { url: "https://downloads.mokaid.com/releases/1.2.3/Mokaid-1.2.3-macos-arm64.dmg", sha256: "a".repeat(64), size: 100_000, minimumOS: "13.0" },
    "windows-x64": { url: "https://downloads.mokaid.com/releases/1.2.3/Mokaid-1.2.3-windows-x64.exe", sha256: "b".repeat(64), size: 200_000, minimumOS: "10.0.22000" },
  },
};

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe("desktop release downloads", () => {
  it("shows no fabricated download links before a release exists", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ status: 404, ok: false }));
    render(<DownloadPage />);
    await screen.findByText("The first public desktop release is not available yet.");
    expect(screen.queryByRole("link", { name: /Download for/ })).not.toBeInTheDocument();
    expect(screen.getAllByRole("button", { name: "Download not available" })).toHaveLength(2);
  });

  it("offers only the two verified versioned artifact links", async () => {
    const fetchRelease = vi.fn().mockResolvedValue({ status: 200, ok: true, json: async () => release });
    vi.stubGlobal("fetch", fetchRelease);
    render(<DownloadPage />);
    expect(await screen.findByRole("link", { name: "Download for macOS" })).toHaveAttribute("href", release.downloads["macos-arm64"].url);
    expect(screen.getByRole("link", { name: "Download for Windows" })).toHaveAttribute("href", release.downloads["windows-x64"].url);
    expect(fetchRelease).toHaveBeenCalledWith("https://downloads.mokaid.com/stable/release.json", expect.objectContaining({ credentials: "omit", redirect: "error" }));
  });

  it("rejects an externally redirected download or a channel mismatch", () => {
    const untrusted = {
      ...release,
      downloads: { ...release.downloads, "macos-arm64": {
        ...release.downloads["macos-arm64"], url: "https://mokaid-downloads.example/installer.dmg",
      } },
    };
    expect(desktopReleaseSchema.safeParse(untrusted).success).toBe(false);
    expect(desktopReleaseSchema.safeParse({ ...release, channel: "beta" }).success).toBe(false);
  });

  it("allows retry and does not retain stale download links after failure", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("offline")));
    render(<DownloadPage />);
    await waitFor(() => expect(screen.getByRole("button", { name: "Retry" })).toBeInTheDocument());
    expect(screen.queryByRole("link", { name: /Download for/ })).not.toBeInTheDocument();
  });
});
