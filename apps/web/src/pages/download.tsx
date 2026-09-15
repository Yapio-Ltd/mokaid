import { useEffect, useState } from "react";
import { Link } from "@tanstack/react-router";
import { ArrowDownToLine, ArrowUpRight, Monitor, RefreshCw } from "lucide-react";
import { z } from "zod";
import { SiteHeader } from "@/components/marketing/site-header";
import { SiteFooter } from "@/components/landing/site-footer";
import { useSeo } from "@/lib/use-seo";

const origin = "https://downloads.mokaid.com";
const versionPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const artifact = z.object({
  url: z.string().url(),
  sha256: z.string().regex(/^[0-9a-f]{64}$/),
  size: z.number().int().positive(),
  minimumOS: z.string().min(1),
});

export const desktopReleaseSchema = z
  .object({
    schemaVersion: z.literal(1),
    version: z.string().regex(versionPattern),
    channel: z.literal("stable"),
    publishedAt: z.string().datetime({ offset: true }),
    releaseNotesUrl: z.string().url(),
    downloads: z.object({ "macos-arm64": artifact, "windows-x64": artifact }),
  })
  .superRefine((release, context) => {
    for (const [platform, extension] of [
      ["macos-arm64", "dmg"],
      ["windows-x64", "exe"],
    ] as const) {
      const expected = `${origin}/releases/${release.version}/Mokaid-${release.version}-${platform}.${extension}`;
      if (release.downloads[platform].url !== expected) {
        context.addIssue({ code: z.ZodIssueCode.custom, message: "Invalid download URL" });
      }
    }
    if (
      release.releaseNotesUrl !==
      `https://github.com/Yapio-Ltd/mokaid/releases/tag/desktop-v${release.version}`
    ) {
      context.addIssue({ code: z.ZodIssueCode.custom, message: "Invalid release notes URL" });
    }
  });

type DesktopRelease = z.infer<typeof desktopReleaseSchema>;
type ReleaseState =
  | { status: "loading" }
  | { status: "unavailable" }
  | { status: "error" }
  | { status: "ready"; release: DesktopRelease };

const platforms = [
  {
    id: "macos-arm64",
    name: "macOS",
    subtitle: "Apple Silicon · macOS 13 or later",
    extension: "DMG",
  },
  {
    id: "windows-x64",
    name: "Windows",
    subtitle: "64-bit Intel / AMD · Windows 11",
    extension: "EXE",
  },
] as const;

export function DownloadPage() {
  useSeo({
    title: "Download Mokaid Desktop",
    description:
      "Your AI workspace, agents and 3D office in the Mokaid desktop application for macOS and Windows.",
    path: "/download",
  });
  const [attempt, setAttempt] = useState(0);
  const [state, setState] = useState<ReleaseState>({ status: "loading" });

  useEffect(() => {
    const controller = new window.AbortController();
    const timeout = window.setTimeout(() => controller.abort(), 15_000);
    let mounted = true;
    setState({ status: "loading" });
    async function loadRelease() {
      try {
        const response = await fetch(`${origin}/stable/release.json`, {
          signal: controller.signal,
          credentials: "omit",
          cache: "no-store",
          redirect: "error",
        });
        if (response.status === 404) {
          if (mounted) setState({ status: "unavailable" });
          return;
        }
        if (!response.ok) throw new Error("Release manifest unavailable");
        const release = desktopReleaseSchema.parse(await response.json());
        if (mounted) setState({ status: "ready", release });
      } catch {
        if (mounted) setState({ status: "error" });
      } finally {
        window.clearTimeout(timeout);
      }
    }
    void loadRelease();
    return () => {
      mounted = false;
      controller.abort();
      window.clearTimeout(timeout);
    };
  }, [attempt]);

  const release = state.status === "ready" ? state.release : null;
  return (
    <div className="min-h-screen bg-bg-deep text-text">
      <SiteHeader />
      <main
        id="main-content"
        tabIndex={-1}
        className="mx-auto max-w-5xl px-6 pb-20 pt-32 sm:px-10 sm:pb-24 sm:pt-40"
      >
        <header className="mb-12 max-w-2xl">
          <h1 className="text-4xl font-semibold tracking-tight sm:text-6xl">
            Your workspace.
            <br />
            At home on your desktop.
          </h1>
          <p className="mt-6 text-lg leading-relaxed text-text-secondary">
            Bring your AI agents, tasks, conversations and 3D office together in one application.
          </p>
        </header>

        <div aria-live="polite" aria-atomic="true" className="mb-6 text-sm text-text-secondary">
          {state.status === "loading" && "Checking the latest desktop release…"}
          {state.status === "unavailable" &&
            "The first public desktop release is not available yet."}
          {state.status === "error" && (
            <div className="flex flex-wrap items-center gap-3">
              <span>We couldn't verify the latest release. Please try again.</span>
              <button
                type="button"
                onClick={() => setAttempt((value) => value + 1)}
                className="mk-focus-ring inline-flex items-center gap-2 rounded-md text-text underline underline-offset-4"
              >
                <RefreshCw size={14} aria-hidden="true" /> Retry
              </button>
            </div>
          )}
          {release &&
            `Version ${release.version} · Released ${new Date(release.publishedAt).toLocaleDateString()}`}
        </div>

        <div className="grid gap-6 sm:grid-cols-2">
          {platforms.map((platform) => {
            const download = release?.downloads[platform.id];
            return (
              <section
                key={platform.id}
                aria-labelledby={`download-${platform.id}`}
                className="rounded-2xl border border-white/10 bg-white/[0.025] p-8"
              >
                <Monitor size={28} aria-hidden="true" className="mb-6 text-primary" />
                <h2 id={`download-${platform.id}`} className="text-2xl font-semibold">
                  {platform.name}
                </h2>
                <p className="mb-8 mt-2 text-sm text-text-secondary">
                  {download
                    ? `${platform.id === "macos-arm64" ? "Apple Silicon" : "64-bit Intel / AMD"} · ${download.minimumOS}`
                    : platform.subtitle}
                </p>
                {download ? (
                  <>
                    <a
                      href={download.url}
                      className="mk-focus-ring inline-flex min-h-12 w-full items-center justify-center gap-2 rounded-xl bg-primary px-5 font-semibold text-white hover:brightness-110"
                    >
                      <ArrowDownToLine size={18} aria-hidden="true" /> Download for {platform.name}
                    </a>
                    <p className="mt-3 text-center text-xs text-text-secondary">
                      {platform.extension} · {(download.size / 1024 / 1024).toFixed(0)} MB
                    </p>
                    <details className="mt-6 text-xs text-text-secondary">
                      <summary className="mk-focus-ring cursor-pointer rounded">
                        Verify SHA-256 checksum
                      </summary>
                      <code className="mt-3 block break-all leading-relaxed select-all">
                        {download.sha256}
                      </code>
                    </details>
                  </>
                ) : (
                  <button
                    type="button"
                    disabled
                    className="min-h-12 w-full cursor-not-allowed rounded-xl border border-white/10 px-5 text-sm text-text-secondary opacity-60"
                  >
                    {state.status === "loading"
                      ? "Checking availability…"
                      : "Download not available"}
                  </button>
                )}
              </section>
            );
          })}
        </div>
        <div className="mt-10 flex flex-wrap items-center justify-between gap-4 text-sm text-text-secondary">
          <p>
            {release
              ? "Signed installers. Future updates are available inside the application."
              : "Downloads appear here after a signed release is published."}
          </p>
          {release && (
            <a
              href={release.releaseNotesUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="mk-focus-ring inline-flex items-center gap-1 rounded-md text-text hover:underline"
            >
              Release notes <ArrowUpRight size={15} aria-hidden="true" />
            </a>
          )}
        </div>
        <section className="mt-14 border-t border-white/10 pt-8">
          <h2 className="text-xl font-semibold">One account, wherever you work.</h2>
          <p className="mt-3 max-w-2xl leading-relaxed text-text-secondary">
            Sign in to the desktop app with your Mokaid account. You can manage your plan, usage,
            payment methods and invoices on the web.
          </p>
          <Link
            to="/account"
            className="mk-focus-ring mt-5 inline-flex min-h-11 items-center gap-2 rounded-md text-primary-light hover:text-text"
          >
            Manage my account <ArrowUpRight size={16} aria-hidden="true" />
          </Link>
        </section>
      </main>
      <SiteFooter />
    </div>
  );
}
