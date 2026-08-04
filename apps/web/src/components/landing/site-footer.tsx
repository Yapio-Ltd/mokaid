import {
  Blocks,
  Bot,
  Building2,
  Cookie,
  Handshake,
  LogIn,
  Rocket,
  RotateCcw,
  Scale,
  Sparkles,
  Webhook,
} from "lucide-react";
import { Footer } from "@/components/ui/footer";
import { CONTACT_EMAIL, LEGAL_ENTITY_NAME } from "@/lib/legal-config";

export function SiteFooter() {
  return (
    <div className="mk-site-footer relative isolate overflow-hidden">
      {/* Soft atmospheric top fade — no hard white line */}
      <div
        className="pointer-events-none absolute inset-x-0 -top-24 h-32 bg-gradient-to-b from-transparent via-primary/[0.04] to-transparent"
        aria-hidden
      />
      <div
        className="pointer-events-none absolute -bottom-20 left-1/4 h-48 w-72 -translate-x-1/2 rounded-full bg-primary/10 blur-[80px]"
        aria-hidden
      />
      <div
        className="pointer-events-none absolute -bottom-16 right-0 h-40 w-56 rounded-full bg-[rgba(100,180,255,0.08)] blur-[70px]"
        aria-hidden
      />

      <Footer
        className="relative mk-glass-footer pt-12 sm:pt-16"
        brand={{
          name: "mokaid",
          description: "The workspace for AI and human employees. Built with care.",
        }}
        socialLinks={[
          {
            name: "Contact",
            href: `mailto:${CONTACT_EMAIL}`,
          },
        ]}
        columns={[
          {
            title: "Product",
            links: [
              {
                name: "Product",
                Icon: Blocks,
                href: "#product",
              },
              {
                name: "Agents",
                Icon: Bot,
                href: "#agents",
              },
              {
                name: "Connectors",
                Icon: Webhook,
                href: "#connectors",
              },
              {
                name: "Why mokaid",
                Icon: Sparkles,
                href: "#why",
              },
            ],
          },
          {
            title: "Account",
            links: [
              {
                name: "Sign in",
                Icon: LogIn,
                href: "/login",
              },
              {
                name: "Get started",
                Icon: Rocket,
                href: "/signup",
              },
            ],
          },
          {
            title: "Legal",
            links: [
              {
                name: "Privacy Policy",
                Icon: Scale,
                href: "/privacy",
              },
              {
                name: "Terms of Service",
                Icon: Handshake,
                href: "/terms",
              },
              {
                name: "Refund & Cancellation",
                Icon: RotateCcw,
                href: "/refund",
              },
              {
                name: "Cookies",
                Icon: Cookie,
                href: "/cookies",
              },
              {
                name: "Legal Notice",
                Icon: Building2,
                href: "/legal",
              },
            ],
          },
        ]}
        copyright={`© ${new Date().getFullYear()} ${LEGAL_ENTITY_NAME}. All rights reserved.`}
      />
    </div>
  );
}
