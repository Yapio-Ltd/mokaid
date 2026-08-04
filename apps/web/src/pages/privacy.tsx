import { Link } from "@tanstack/react-router";
import { Shield } from "lucide-react";
import {
  EntityContactCard,
  LegalDocLayout,
  Prose,
  SectionTitle,
  SubList,
} from "@/components/legal/legal-doc-layout";
import {
  CONTACT_EMAIL,
  HOSTING_PROVIDER,
  LEGAL_ENTITY_NAME,
  PAYMENT_PROVIDER,
  PRODUCT_NAME,
  SITE_DOMAIN,
} from "@/lib/legal-config";

export function PrivacyPage() {
  return (
    <LegalDocLayout
      icon={Shield}
      title="Privacy Policy"
      excludeFooterLink="/privacy"
      intro={
        <>
          <p className="mt-3 text-sm leading-relaxed text-text-secondary">
            {LEGAL_ENTITY_NAME} (&quot;we&quot;, &quot;us&quot;, or &quot;our&quot;) operates the{" "}
            {PRODUCT_NAME} platform at{" "}
            <strong className="text-text">{SITE_DOMAIN}</strong>. This Privacy Policy explains
            what personal data we collect, why we process it, how we protect it, and your rights
            under:
          </p>
          <ul className="mt-2 space-y-1 text-sm text-text-secondary">
            <li className="flex gap-2">
              <span className="text-primary-light">•</span>
              the Israeli Protection of Privacy Law 5741-1981, as amended (including Amendment
              13), and the Privacy Protection Regulations (Data Security), 5777-2017 (the
              &quot;PPL&quot;); and
            </li>
            <li className="flex gap-2">
              <span className="text-primary-light">•</span>
              where applicable, the EU/UK General Data Protection Regulation
              (&quot;GDPR&quot;) and comparable international privacy laws.
            </li>
          </ul>
          <p className="mt-3 text-sm leading-relaxed text-text-secondary">
            By using the {PRODUCT_NAME} platform, you acknowledge that you have read this Privacy
            Policy. If you do not agree, please do not use the service.
          </p>
        </>
      }
    >
      <section>
        <SectionTitle index="1" title="Data controller and database owner" />
        <Prose>
          The controller of personal data (and, under Israeli law, the database owner) for the{" "}
          {PRODUCT_NAME} service is:
        </Prose>
        <EntityContactCard attention="Privacy inquiries" />
        <Prose className="mt-4">
          For privacy requests, contact us at{" "}
          <a href={`mailto:${CONTACT_EMAIL}`} className="text-primary-light hover:underline">
            {CONTACT_EMAIL}
          </a>
          . We will verify your identity before acting on certain requests.
        </Prose>
      </section>

      <section>
        <SectionTitle index="2" title="Data we collect" />
        <Prose>
          We collect personal data depending on how you interact with {PRODUCT_NAME}:
        </Prose>
        <SubList
          items={[
            {
              label: "Account data",
              detail:
                "Full name, email address, password (hashed), optional profile photo, locale preferences.",
            },
            {
              label: "Workspace and usage data",
              detail:
                "Actions on the platform, pages visited, session duration, feature usage, and interface events.",
            },
            {
              label: "AI agent data",
              detail:
                "Instructions, assigned tasks, conversation history with agents, and produced outputs you generate while using the service.",
            },
            {
              label: "Integration data",
              detail:
                "OAuth tokens and related metadata for third-party integrations you enable (e.g. GitHub, Google, Figma).",
            },
            {
              label: "Payment data",
              detail: `Billing and payment metadata processed by our payment provider (${PAYMENT_PROVIDER}). We do not store full payment card numbers on our systems.`,
            },
            {
              label: "Technical data",
              detail:
                "IP address, browser type, operating system, device identifiers, and server logs for security, fraud prevention, and debugging.",
            },
            {
              label: "Communications",
              detail: "Messages you send to support or other contact channels.",
            },
          ]}
        />
        <Prose className="mt-4">
          We do not intentionally collect special-category data (e.g. racial or ethnic origin,
          political opinions, health data, biometric templates for identification) under GDPR, or
          sensitive information beyond what you voluntarily place in platform content. Please do
          not submit such data unless necessary for your legitimate use of the service.
        </Prose>
      </section>

      <section>
        <SectionTitle index="3" title="Purposes and legal bases" />
        <Prose>
          We process personal data only for the purposes described below. For Israeli PPL purposes,
          processing is limited to the purposes for which the data was collected or compatible
          purposes permitted by law. Where GDPR applies, each activity rests on a legal basis under
          Article 6 GDPR:
        </Prose>
        <table className="mt-4 w-full overflow-hidden rounded-lg border border-border text-sm">
          <thead>
            <tr className="border-b border-border bg-surface">
              <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-text-muted">
                Purpose
              </th>
              <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-text-muted">
                Legal basis (GDPR)
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border/50">
            {[
              ["Account creation and management", "Contract performance (Art. 6.1.b)"],
              ["Providing platform features (incl. AI agents)", "Contract performance (Art. 6.1.b)"],
              ["Transactional and service emails", "Contract performance (Art. 6.1.b)"],
              ["Billing and subscription management", "Contract / legal obligation (Art. 6.1.b, c)"],
              ["Security, fraud prevention, abuse detection", "Legitimate interest (Art. 6.1.f)"],
              ["Service improvement (aggregated / limited)", "Legitimate interest (Art. 6.1.f)"],
              ["Marketing communications (opt-in)", "Consent (Art. 6.1.a)"],
              ["Non-essential analytics cookies", "Consent (Art. 6.1.a)"],
              ["Complying with legal requirements", "Legal obligation (Art. 6.1.c)"],
            ].map(([purpose, basis]) => (
              <tr key={purpose} className="text-text-secondary">
                <td className="px-4 py-3">{purpose}</td>
                <td className="px-4 py-3 text-xs text-text-muted">{basis}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      <section>
        <SectionTitle index="4" title="AI processing transparency" />
        <Prose>
          {PRODUCT_NAME} uses artificial intelligence features (agents, models, and related
          tooling) to generate content and execute tasks you request. Content you provide
          (prompts, documents, instructions) and resulting outputs may be processed by us and by
          sub-processors solely to deliver those features. We do not sell your content to train
          public third-party foundation models for unrelated purposes. You remain responsible for
          what you submit to AI features and for reviewing outputs before relying on them.
        </Prose>
      </section>

      <section>
        <SectionTitle index="5" title="Retention periods" />
        <Prose>
          We keep personal data only as long as needed for the purposes above or as required by
          law:
        </Prose>
        <SubList
          items={[
            {
              label: "Active account data",
              detail: "For the duration of your contractual relationship with us.",
            },
            {
              label: "Data after account closure",
              detail:
                "Approximately 30 days (grace period for reactivation), then permanent deletion or anonymization, except where legal retention applies.",
            },
            {
              label: "Billing and tax records",
              detail:
                "Typically 7 years (and longer if required under Israeli tax or bookkeeping rules), in line with accounting and tax obligations.",
            },
            {
              label: "Technical logs",
              detail: "Up to 90 days for security and debugging, unless needed longer for an investigation.",
            },
            {
              label: "Marketing data (opt-in)",
              detail: "Until you withdraw consent or unsubscribe.",
            },
          ]}
        />
      </section>

      <section>
        <SectionTitle index="6" title="Sharing and recipients" />
        <Prose>
          We do not sell your personal data. We may share data only as follows:
        </Prose>
        <SubList
          items={[
            {
              label: "Technical processors",
              detail: `Hosting (${HOSTING_PROVIDER}), database, email delivery, and infrastructure providers bound by written processing terms.`,
            },
            {
              label: "Payment provider",
              detail: `${PAYMENT_PROVIDER} processes payments and related billing data under its own terms and privacy policy.`,
            },
            {
              label: "Third-party integrations",
              detail:
                "GitHub, Google Workspace, Figma, and similar services — only if you enable them and within the permissions you grant.",
            },
            {
              label: "Legal and safety",
              detail:
                "Competent authorities, courts, or advisors when required by law, to protect rights, or in connection with a merger or corporate transaction (with notice where required).",
            },
          ]}
        />
      </section>

      <section>
        <SectionTitle index="7" title="International transfers" />
        <Prose>
          We and our processors may process data outside Israel, including in the European
          Economic Area, the United Kingdom, and the United States. For transfers that require
          safeguards, we rely on appropriate measures such as Standard Contractual Clauses
          (SCCs), adequacy decisions where available, and contractual/security obligations under
          Israeli and international law.
        </Prose>
      </section>

      <section>
        <SectionTitle index="8" title="Cookies and similar technologies" />
        <Prose>
          {PRODUCT_NAME} uses cookies and similar technologies as described in our{" "}
          <Link to="/cookies" className="text-primary-light hover:underline">
            Cookie Policy
          </Link>
          . Strictly necessary cookies run to provide the service. Analytics and other
          non-essential cookies are used only with your consent where required.
        </Prose>
      </section>

      <section>
        <SectionTitle index="9" title="Data security" />
        <Prose>
          Taking into account the nature of the data and risks under the Israeli Privacy
          Protection Regulations (Data Security), we implement appropriate technical and
          organizational measures, including:
        </Prose>
        <SubList
          items={[
            {
              label: "Encryption in transit",
              detail: "HTTPS / TLS for network traffic; passwords stored using modern hashing.",
            },
            {
              label: "Access control",
              detail: "Least-privilege access for personnel and systems; authentication controls.",
            },
            {
              label: "Monitoring and logging",
              detail: "Security-oriented logging and anomaly awareness on production systems.",
            },
            {
              label: "Backups",
              detail: "Periodic backups with restore procedures appropriate to the service.",
            },
          ]}
        />
        <Prose className="mt-4">
          No method of transmission or storage is perfectly secure. If a personal data breach is
          likely to cause a risk to your rights, we will notify you and, where required, the
          Israeli Privacy Protection Authority and/or relevant EU supervisory authorities without
          undue delay (and, where GDPR applies, aiming to meet the 72-hour regulator
          notification standard where mandatory).
        </Prose>
      </section>

      <section>
        <SectionTitle index="10" title="Your rights" />
        <Prose>
          Depending on applicable law (PPL, GDPR, or other), you may have rights including:
        </Prose>
        <SubList
          items={[
            {
              label: "Access",
              detail: "Obtain confirmation and a copy of personal data we hold about you.",
            },
            {
              label: "Rectification",
              detail: "Correct inaccurate or incomplete data.",
            },
            {
              label: "Erasure / deletion",
              detail: "Request deletion, subject to legal retention and contractual needs.",
            },
            {
              label: "Restriction or objection",
              detail: "Limit or object to certain processing, including direct marketing.",
            },
            {
              label: "Portability (where GDPR applies)",
              detail: "Receive data in a structured, commonly used, machine-readable format.",
            },
            {
              label: "Withdraw consent",
              detail: "Where processing is based on consent, withdraw it at any time without affecting prior lawful processing.",
            },
          ]}
        />
        <Prose className="mt-4">
          Exercise rights by emailing{" "}
          <a href={`mailto:${CONTACT_EMAIL}`} className="text-primary-light hover:underline">
            {CONTACT_EMAIL}
          </a>
          . We respond within a reasonable period (typically within one month under GDPR, subject to
          permitted extensions). You may also lodge a complaint with:
        </Prose>
        <SubList
          items={[
            {
              label: "Israel",
              detail:
                "the Privacy Protection Authority (PPA) — https://www.gov.il/en/departments/the_privacy_protection_authority",
            },
            {
              label: "EU / EEA",
              detail:
                "your local data protection supervisory authority (a list is available from the European Data Protection Board).",
            },
          ]}
        />
      </section>

      <section>
        <SectionTitle index="11" title="Controller / processor roles for workspaces" />
        <Prose>
          When you use {PRODUCT_NAME} as a workspace for your organization, you (or your
          organization) may act as controller of personal data relating to your members and
          end-content. In that case, {LEGAL_ENTITY_NAME} acts as a processor on your instructions.
          A Data Processing Agreement (DPA) is available on request at{" "}
          <a href={`mailto:${CONTACT_EMAIL}`} className="text-primary-light hover:underline">
            {CONTACT_EMAIL}
          </a>
          .
        </Prose>
      </section>

      <section>
        <SectionTitle index="12" title="Children" />
        <Prose>
          {PRODUCT_NAME} is intended for business and professional users who are at least 16 years
          old (or older where local law requires majority for binding contracts — typically 18). We
          do not knowingly collect personal data from children. If you believe a minor has provided
          us personal data, contact us so we can delete it.
        </Prose>
      </section>

      <section>
        <SectionTitle index="13" title="Changes to this policy" />
        <Prose>
          We may update this Privacy Policy to reflect legal, technical, or product changes. The
          &quot;Last updated&quot; date at the top will change when we do. For material changes, we
          will provide notice by email or in-product communication within a reasonable time before
          the changes take effect where required by law.
        </Prose>
      </section>

      <section>
        <SectionTitle index="14" title="Contact" />
        <Prose>
          For any question, request, or complaint about personal data protection:
        </Prose>
        <EntityContactCard attention="Privacy" />
      </section>
    </LegalDocLayout>
  );
}
