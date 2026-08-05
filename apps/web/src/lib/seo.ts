/** Site-wide SEO constants and JSON-LD builders for the public marketing pages. */

export const SITE = {
  name: "mokaid",
  url: "https://mokaid.com",
  tagline: "AI Workforce OS",
  defaultTitle: "mokaid | AI Employees in a 3D Virtual Office — AI Workforce OS",
  defaultDescription:
    "Hire autonomous AI employees you can actually see. mokaid is the AI Workforce OS: a real-time 3D virtual office where your AI agents work, collaborate, and report to you.",
  ogImage: "https://mokaid.com/branding/og-image-wide.jpg",
  twitterHandle: "@mokaid_ai",
} as const;

export function canonicalUrl(path: string): string {
  const clean = path === "/" ? "/" : path.replace(/\/+$/, "");
  return `${SITE.url}${clean}`;
}

export const ORGANIZATION_JSONLD = {
  "@context": "https://schema.org",
  "@type": "Organization",
  "@id": `${SITE.url}/#organization`,
  name: SITE.name,
  url: SITE.url,
  logo: {
    "@type": "ImageObject",
    url: `${SITE.url}/branding/logo-with-bg.png`,
  },
  description:
    "mokaid is the AI Workforce OS — a platform for hiring and managing autonomous AI employees inside a real-time 3D virtual office.",
  sameAs: ["https://x.com/mokaid_ai", "https://www.linkedin.com/company/mokaid"],
};

export const SOFTWARE_JSONLD = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  "@id": `${SITE.url}/#software`,
  name: "mokaid",
  applicationCategory: "BusinessApplication",
  operatingSystem: "Web",
  url: SITE.url,
  description:
    "AI Workforce OS: hire autonomous AI employees — SDRs, marketers, developers, assistants — and watch them work in a real-time 3D virtual office with tasks, approvals, and full audit trails.",
  offers: {
    "@type": "Offer",
    price: "0",
    priceCurrency: "USD",
    description: "Free to start. Paid plans scale with your AI workforce.",
  },
  publisher: { "@id": `${SITE.url}/#organization` },
};

export interface BreadcrumbItem {
  name: string;
  path: string;
}

export function breadcrumbJsonLd(items: BreadcrumbItem[]) {
  return {
    "@context": "https://schema.org",
    "@type": "BreadcrumbList",
    itemListElement: items.map((item, i) => ({
      "@type": "ListItem",
      position: i + 1,
      name: item.name,
      item: canonicalUrl(item.path),
    })),
  };
}

export interface FaqItem {
  question: string;
  answer: string;
}

export function faqJsonLd(items: FaqItem[]) {
  return {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: items.map((item) => ({
      "@type": "Question",
      name: item.question,
      acceptedAnswer: { "@type": "Answer", text: item.answer },
    })),
  };
}
