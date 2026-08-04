import { Link } from "@tanstack/react-router";
import { FileText } from "lucide-react";
import {
  EntityContactCard,
  LegalDocLayout,
  Prose,
  SectionTitle,
  SubList,
} from "@/components/legal/legal-doc-layout";
import {
  CONTACT_EMAIL,
  GOVERNING_LAW,
  JURISDICTION_COURTS,
  LEGAL_ENTITY_NAME,
  PAYMENT_PROVIDER,
  PRODUCT_NAME,
  SITE_DOMAIN,
} from "@/lib/legal-config";

export function TermsPage() {
  return (
    <LegalDocLayout
      icon={FileText}
      title="Terms of Service"
      excludeFooterLink="/terms"
      intro={
        <>
          <p className="mt-3 text-sm leading-relaxed text-text-secondary">
            These Terms of Service (the &quot;Terms&quot;) govern access to and use of the{" "}
            {PRODUCT_NAME} platform, available at{" "}
            <strong className="text-text">{SITE_DOMAIN}</strong>, operated by{" "}
            <strong className="text-text">{LEGAL_ENTITY_NAME}</strong> (&quot;we&quot;,
            &quot;us&quot;, or &quot;our&quot;). {PRODUCT_NAME} is a product of{" "}
            {LEGAL_ENTITY_NAME}.
          </p>
          <p className="mt-3 text-sm leading-relaxed text-text-secondary">
            By creating an account, accessing, or using the platform, you agree to these Terms. If
            you do not accept them, you must stop using the platform immediately.
          </p>
        </>
      }
    >
      <section>
        <SectionTitle index="1" title="Service overview" />
        <Prose>
          {PRODUCT_NAME} is a Software-as-a-Service (SaaS) platform that lets companies and teams
          manage human collaborators and artificial intelligence (AI) agents together in a unified
          workspace.
        </Prose>
        <Prose className="mt-3">The platform may include features such as:</Prose>
        <SubList
          items={[
            "Creation, configuration, and supervision of AI agents.",
            "Project, task, and mixed workflow management (humans + AI).",
            "Team dashboards and analytics.",
            "Shared knowledge base and document management.",
            "Integrations with third-party services (GitHub, Google Workspace, Figma, etc.).",
            "Internal messaging, calendar, and related productivity tools.",
            "Billing and subscription management.",
          ]}
        />
        <Prose className="mt-4">
          We may evolve, add, or remove features at any time, subject to Section 14 (Changes) and
          any mandatory consumer protections that apply to you.
        </Prose>
      </section>

      <section>
        <SectionTitle index="2" title="Access and account creation" />
        <Prose>
          Access to {PRODUCT_NAME} requires a user account. To sign up, you must:
        </Prose>
        <SubList
          items={[
            "Be a natural person at least 18 years old (or the age of majority in your jurisdiction), or act for a legally constituted entity.",
            "Provide accurate registration information and keep it up to date.",
            "Have legal capacity to be bound by these Terms.",
            "Not have had an account suspended or terminated for breach.",
          ]}
        />
        <Prose className="mt-4">
          You are responsible for keeping credentials confidential. Activity under your account is
          deemed yours. Notify us immediately of unauthorized access at{" "}
          <a href={`mailto:${CONTACT_EMAIL}`} className="text-primary-light hover:underline">
            {CONTACT_EMAIL}
          </a>
          .
        </Prose>
        <Prose className="mt-3">
          We may refuse registration or access where reasonably necessary for security, legal
          compliance, or abuse prevention.
        </Prose>
      </section>

      <section>
        <SectionTitle index="3" title="Workspaces" />
        <Prose>
          The platform is organized around workspaces. Workspace administrators typically may:
        </Prose>
        <SubList
          items={[
            "Invite and revoke members.",
            "Configure AI agents and integrations.",
            "Manage billing and subscriptions.",
            "View workspace data and logs within their permissions.",
          ]}
        />
        <Prose className="mt-4">
          The administrator is responsible for ensuring workspace members comply with these Terms
          and for obtaining any required consents from members whose data is processed in the
          workspace.
        </Prose>
      </section>

      <section>
        <SectionTitle index="4" title="Artificial intelligence agents" />
        <Prose>
          {PRODUCT_NAME} lets you create and manage AI agents. You acknowledge and agree that:
        </Prose>
        <SubList
          items={[
            "AI agents generate content and take actions based on instructions and data you provide; you are solely responsible for those instructions and for how you use the outputs.",
            "AI outputs are provided “as is” and may contain errors, hallucinations, or omissions.",
            "You must verify outputs before relying on them for critical purposes (including legal, medical, financial, or safety-critical use).",
            "You must not use AI features to produce unlawful, discriminatory, misleading content, or content that infringes third-party rights.",
            `${LEGAL_ENTITY_NAME} is not liable for decisions made by you or third parties based on AI outputs, to the fullest extent permitted by law.`,
          ]}
        />
      </section>

      <section>
        <SectionTitle index="5" title="Acceptable use" />
        <Prose>You must not:</Prose>
        <SubList
          items={[
            "Use the platform for unlawful purposes or in breach of these Terms.",
            "Reproduce, resell, or sublicense access without prior written authorization.",
            "Attempt unauthorized access to systems, data, or accounts.",
            "Circumvent security measures or rate limits.",
            "Introduce malware or interfere with service integrity.",
            "Send spam, phishing, or unsolicited bulk communications via the service.",
            "Scrape or automate access in ways that harm the service, outside permitted APIs.",
            "Impersonate another person or entity.",
            `Infringe intellectual property rights of ${LEGAL_ENTITY_NAME} or others.`,
            "Violate privacy or data protection rights of others.",
          ]}
        />
        <Prose className="mt-4">
          Breach may lead to suspension or termination without prejudice to other remedies.
        </Prose>
      </section>

      <section>
        <SectionTitle index="6" title="Intellectual property" />
        <Prose>
          <strong className="text-text">{PRODUCT_NAME} and the platform.</strong> The platform,
          source code, design, trademarks, logos, algorithms, and documentation are owned by{" "}
          {LEGAL_ENTITY_NAME} or its licensors and protected by applicable IP laws. No license is
          granted beyond the limited right to use the service under these Terms.
        </Prose>
        <Prose className="mt-4">
          <strong className="text-text">Your content.</strong> You retain rights in content you
          create, import, or process. You grant {LEGAL_ENTITY_NAME} a limited, worldwide,
          non-exclusive license to host, process, transmit, and display that content solely to
          provide and secure the service.
        </Prose>
        <Prose className="mt-4">
          <strong className="text-text">AI-generated content.</strong> As between you and{" "}
          {LEGAL_ENTITY_NAME}, rights in content generated by agents you configure are attributed
          to you, subject to third-party model/provider terms and applicable law on AI-generated
          works.
        </Prose>
      </section>

      <section>
        <SectionTitle index="7" title="Personal data and privacy" />
        <Prose>
          Processing of personal data is governed by our{" "}
          <Link to="/privacy" className="text-primary-light hover:underline">
            Privacy Policy
          </Link>
          , which forms part of these Terms.
        </Prose>
        <Prose className="mt-3">
          As a workspace administrator, you may be a controller of members&apos; personal data.{" "}
          {LEGAL_ENTITY_NAME} then acts as a processor. A Data Processing Agreement is available
          on request at{" "}
          <a href={`mailto:${CONTACT_EMAIL}`} className="text-primary-light hover:underline">
            {CONTACT_EMAIL}
          </a>
          .
        </Prose>
      </section>

      <section>
        <SectionTitle index="8" title="Third-party integrations" />
        <Prose>
          The platform may connect to third-party services (GitHub, Google Workspace, Figma,{" "}
          {PAYMENT_PROVIDER}, etc.). Those services are subject to their own terms and privacy
          policies. {LEGAL_ENTITY_NAME} is not responsible for outages or changes by third parties.
          Enabling an integration authorizes us to access that service within the permissions you
          grant.
        </Prose>
      </section>

      <section>
        <SectionTitle index="9" title="Pricing, subscriptions, and billing" />
        <Prose>
          Certain features require a paid subscription or purchase of AI credit packs. By
          subscribing or purchasing:
        </Prose>
        <SubList
          items={[
            "You accept the prices shown at checkout for the selected plan or credit pack.",
            `Payment is processed by ${PAYMENT_PROVIDER}, our payment service provider.`,
            "Paid subscriptions renew automatically at the end of each billing period unless canceled before renewal.",
            "You may manage or cancel your subscription from workspace billing settings where available, or by contacting support.",
            "Refunds and cancellations are governed by our Refund & Cancellation Policy.",
            "Non-payment may lead to suspension or downgrade of access.",
          ]}
        />
        <Prose className="mt-4">
          Full cancellation and refund rules (including consumer cooling-off rights under Israeli
          law where applicable) are set out in our{" "}
          <Link to="/refund" className="text-primary-light hover:underline">
            Refund & Cancellation Policy
          </Link>
          , which forms part of these Terms.
        </Prose>
        <Prose className="mt-3">
          We may change prices with at least 30 days&apos; notice for recurring subscriptions. If
          you disagree, cancel before the new prices take effect.
        </Prose>
      </section>

      <section>
        <SectionTitle index="10" title="Service availability and maintenance" />
        <Prose>
          We aim to keep {PRODUCT_NAME} available, but we do not guarantee uninterrupted or
          error-free operation. Interruptions may occur for maintenance, updates, force majeure, or
          third-party infrastructure issues. We try to notify planned maintenance with reasonable
          notice when practicable.
        </Prose>
      </section>

      <section>
        <SectionTitle index="11" title="Limitation of liability" />
        <Prose>To the fullest extent permitted by applicable law:</Prose>
        <SubList
          items={[
            "The platform is provided “as is” and “as available” without warranties of merchantability, fitness for a particular purpose, or non-infringement, except warranties that cannot be excluded by law.",
            `${LEGAL_ENTITY_NAME} is not liable for indirect, incidental, special, consequential, or punitive damages, loss of profits, data, or goodwill arising from use of the platform.`,
            `Our aggregate liability arising out of these Terms is limited to the amounts you paid to ${LEGAL_ENTITY_NAME} for the service in the twelve (12) months preceding the claim.`,
            "Nothing in these Terms limits liability for fraud, willful misconduct, death or personal injury caused by negligence, or any liability that cannot be limited under Israeli law or other mandatory law.",
          ]}
        />
      </section>

      <section>
        <SectionTitle index="12" title="Suspension and termination" />
        <Prose>
          <strong className="text-text">By you.</strong> You may close your account at any time
          from profile/settings or by contacting support. Closing your account results in deletion
          or anonymization of data as described in the Privacy Policy, subject to legal retention.
        </Prose>
        <Prose className="mt-4">
          <strong className="text-text">By us.</strong> We may suspend or terminate access, with or
          without notice where appropriate, for:
        </Prose>
        <SubList
          items={[
            "Breach of these Terms or the Privacy Policy.",
            "Non-payment.",
            "Fraudulent, abusive, or illegal use.",
            "Legal or regulatory requirement or court order.",
            "Permanent discontinuation of the service (with reasonable notice where practicable).",
          ]}
        />
        <Prose className="mt-4">
          Termination for your breach does not entitle you to a refund, except where mandatory law
          requires otherwise. If we permanently discontinue the service, we will use reasonable
          efforts to notify you in advance and help you export data.
        </Prose>
      </section>

      <section>
        <SectionTitle index="13" title="Governing law, disputes, and consumer rights" />
        <Prose>
          These Terms are governed by {GOVERNING_LAW}, without regard to conflict-of-law rules.
          Subject to mandatory protections that apply to you, disputes will be submitted to{" "}
          {JURISDICTION_COURTS}, after good-faith attempts to resolve the matter amicably within
          sixty (60) days of written notice of the dispute.
        </Prose>
        <Prose className="mt-3">
          If you are a &quot;consumer&quot; under the Israeli Consumer Protection Law 5741-1981
          (or equivalent mandatory consumer law in your country), nothing in these Terms limits
          rights that cannot be waived by contract, including applicable distance-selling and
          cancellation rights described in our{" "}
          <Link to="/refund" className="text-primary-light hover:underline">
            Refund & Cancellation Policy
          </Link>
          .
        </Prose>
      </section>

      <section>
        <SectionTitle index="14" title="Changes to the Terms" />
        <Prose>
          We may modify these Terms. For material changes, we will provide notice by email and/or
          in-product notification, generally at least 30 days before the changes take effect where
          practicable. Continued use after the effective date constitutes acceptance, except where
          mandatory law requires separate consent. If you disagree, stop using the service and
          cancel before the effective date.
        </Prose>
      </section>

      <section>
        <SectionTitle index="15" title="Severability and entire agreement" />
        <Prose>
          If any provision is held unenforceable, the remaining provisions remain in effect. These
          Terms, together with the Privacy Policy, Cookie Policy, Refund & Cancellation Policy, and
          any order forms or DPA, constitute the entire agreement between you and{" "}
          {LEGAL_ENTITY_NAME} regarding the service and supersede prior conflicting agreements on
          the same subject.
        </Prose>
      </section>

      <section>
        <SectionTitle index="16" title="Contact" />
        <Prose>For questions about these Terms:</Prose>
        <EntityContactCard />
      </section>
    </LegalDocLayout>
  );
}
