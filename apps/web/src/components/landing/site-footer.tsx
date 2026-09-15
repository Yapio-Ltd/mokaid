import {
  BadgeDollarSign,
  BarChart3,
  Blocks,
  BookOpen,
  BookText,
  Bot,
  Building2,
  Cookie,
  CreditCard,
  Download,
  GitCompare,
  Handshake,
  Lightbulb,
  LogIn,
  Rocket,
  RotateCcw,
  Scale,
  Sparkles,
  Users,
  UserRound,
  Webhook,
} from "lucide-react";
import { Footer } from "@/components/ui/footer";
import { CONTACT_EMAIL, LEGAL_ENTITY_NAME } from "@/lib/legal-config";
import { useAuthStore } from "@/stores/auth-store";

export function SiteFooter() {
  const token = useAuthStore((state) => state.token);

  return (
    <footer aria-label="Site footer" className="mk-site-footer relative isolate overflow-hidden">
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
          description:
            "Your AI team in one desktop app. Your account, usage and billing on the web.",
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
                href: "/#product",
              },
              {
                name: "Agents",
                Icon: Bot,
                href: "/#agents",
              },
              {
                name: "Connectors",
                Icon: Webhook,
                href: "/#connectors",
              },
              {
                name: "Why mokaid",
                Icon: Sparkles,
                href: "/#why",
              },
              {
                name: "Pricing",
                Icon: BadgeDollarSign,
                href: "/pricing",
              },
              { name: "Download desktop", Icon: Download, href: "/download" },
            ],
          },
          {
            title: "Resources",
            links: [
              {
                name: "AI Employees",
                Icon: Users,
                href: "/ai-employees",
              },
              {
                name: "Use Cases",
                Icon: Lightbulb,
                href: "/use-cases",
              },
              {
                name: "Compare",
                Icon: GitCompare,
                href: "/compare",
              },
              {
                name: "Blog",
                Icon: BookOpen,
                href: "/blog",
              },
              {
                name: "Glossary",
                Icon: BookText,
                href: "/glossary",
              },
            ],
          },
          {
            title: "Account",
            links: [
              {
                name: token ? "My account" : "Sign in",
                Icon: token ? UserRound : LogIn,
                href: token ? "/account" : "/login",
              },
              {
                name: "Usage & spending",
                Icon: BarChart3,
                href: "/account/usage",
              },
              { name: "Billing & invoices", Icon: CreditCard, href: "/account/billing" },
              { name: "Manage plan", Icon: BadgeDollarSign, href: "/account/plans" },
              ...(!token ? [{ name: "Create account", Icon: Rocket, href: "/signup" }] : []),
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
        designCredit={{
          href: "https://www.yapio.io/",
          name: "Yapio",
          logoSrc: "/branding/icononly_nav.webp",
          label: "Powered by Yapio — design and product engineering",
        }}
      />
    </footer>
  );
}
