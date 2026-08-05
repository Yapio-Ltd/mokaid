export interface GlossaryTerm {
  slug: string;
  term: string;
  /** One-paragraph, quotable definition (GEO-ready). */
  definition: string;
  detail: string;
  related?: string[];
}

export const glossaryTerms: GlossaryTerm[] = [
  {
    slug: "ai-employee",
    term: "AI Employee",
    definition:
      "An AI employee is an autonomous, role-based AI worker with a persistent identity, defined responsibilities, access to real business tools, and accountability for outcomes — managed like a team member rather than operated like software.",
    detail:
      "Unlike a chatbot or a one-shot AI agent, an AI employee keeps working between your prompts: it holds a queue of tasks, remembers context across sessions, escalates decisions through approval gates, and reports on its work. In mokaid, each AI employee also has a visible presence in the 3D office.",
    related: ["ai-agent", "digital-worker", "ai-workforce"],
  },
  {
    slug: "ai-agent",
    term: "AI Agent",
    definition:
      "An AI agent is a software system that uses AI models to reason about a goal, plan steps, and take actions with tools — typically for bounded tasks with a defined start and end.",
    detail:
      "Agents are the building blocks of AI employees. An agent can research a company or draft an email; an AI employee strings thousands of such runs into a durable role with identity, memory, and governance.",
    related: ["ai-employee", "autonomous-agent"],
  },
  {
    slug: "ai-workforce",
    term: "AI Workforce",
    definition:
      "An AI workforce is the managed collective of AI employees, agents, and automations working alongside humans in an organization — with defined roles, permissions, and oversight.",
    detail:
      "Ten disconnected bots are not a workforce; they are an unmanaged tool inventory. A workforce implies a registry of who exists, what they own, what they may touch, and how they are reviewed — which is exactly what an AI Workforce OS provides.",
    related: ["ai-workforce-os", "ai-employee"],
  },
  {
    slug: "ai-workforce-os",
    term: "AI Workforce OS",
    definition:
      "An AI Workforce OS is the operating layer for running AI employees at work: identity, task routing, permissions, knowledge, approvals, observability, and cost control in one system.",
    detail:
      "The term parallels 'operating system' deliberately: individual AI workers are the applications; the Workforce OS is what makes them coexist safely and productively. mokaid adds a spatial interface — a real-time 3D office — so the entire workforce is visible at a glance.",
    related: ["ai-workforce", "virtual-office"],
  },
  {
    slug: "digital-worker",
    term: "Digital Worker",
    definition:
      "A digital worker is a role-based software entity that owns an entire business function end to end, potentially orchestrating multiple AI agents and integrations to fulfill its role.",
    detail:
      "The term originated in the RPA era and now overlaps heavily with 'AI employee'. Both describe persistent, accountable, role-holding AI workers as opposed to task-scoped agents.",
    related: ["ai-employee", "ai-agent"],
  },
  {
    slug: "virtual-office",
    term: "Virtual Office (for AI)",
    definition:
      "A virtual office for AI is a real-time spatial workspace — in mokaid's case, a 3D office — where AI employees are visible at desks, showing who exists, what they are working on, and how work flows between them.",
    detail:
      "Spatial representation solves the biggest trust problem with autonomous AI: invisibility. When you can see your AI workforce the way you see a real team, supervision becomes ambient instead of forensic.",
    related: ["ai-workforce-os", "observability"],
  },
  {
    slug: "autonomous-agent",
    term: "Autonomous Agent",
    definition:
      "An autonomous agent is an AI system that pursues goals over multiple steps with minimal human intervention — planning, using tools, evaluating results, and correcting course on its own.",
    detail:
      "Autonomy is a spectrum, not a binary. Production systems pair autonomy with guardrails: scoped permissions, approval gates for consequential actions, and audit trails for everything.",
    related: ["ai-agent", "approval-gate"],
  },
  {
    slug: "human-in-the-loop",
    term: "Human-in-the-Loop (HITL)",
    definition:
      "Human-in-the-loop is a design pattern where humans review, approve, or correct AI output at defined checkpoints before it takes effect.",
    detail:
      "HITL is how teams build trust in AI employees progressively: start by reviewing everything, measure quality, then loosen gates category by category. It converts 'do I trust AI?' into a tunable dial.",
    related: ["approval-gate", "ai-employee"],
  },
  {
    slug: "approval-gate",
    term: "Approval Gate",
    definition:
      "An approval gate is a governance checkpoint that pauses an AI employee's action — sending an email, merging code, issuing a refund — until a human approves it.",
    detail:
      "Gates are configured per employee and per action category. They are the practical mechanism behind human-in-the-loop management and the reason AI employees can be trusted with real system access.",
    related: ["human-in-the-loop"],
  },
  {
    slug: "mcp",
    term: "MCP (Model Context Protocol)",
    definition:
      "MCP is an open protocol that lets AI systems connect to external tools and data sources through standardized servers, so one integration works across many AI applications.",
    detail:
      "mokaid uses MCP connectors to give AI employees governed access to tools like Slack, Gmail, Notion, GitHub, and Linear — real read/write access with permissions and audit logs, not copy-paste.",
    related: ["ai-employee"],
  },
  {
    slug: "agent-orchestration",
    term: "Agent Orchestration",
    definition:
      "Agent orchestration is the coordination of multiple AI agents or employees on shared work: routing tasks, sequencing handoffs, sharing context, and resolving conflicts.",
    detail:
      "Orchestration is what separates a workforce from a pile of bots. In mokaid, orchestration is visible: you can watch one AI employee hand a task to another on the office floor.",
    related: ["ai-workforce", "ai-workforce-os"],
  },
  {
    slug: "agent-memory",
    term: "Agent Memory",
    definition:
      "Agent memory is the persistent store of context an AI worker retains across sessions — preferences, past decisions, domain knowledge, and feedback — so performance compounds over time.",
    detail:
      "Memory is a defining trait of AI employees versus stateless agents: an employee corrected once should stay corrected. Memory paired with knowledge bases is how AI employees develop genuine institutional knowledge.",
    related: ["ai-employee", "knowledge-base"],
  },
  {
    slug: "knowledge-base",
    term: "Knowledge Base (AI Training)",
    definition:
      "In an AI workforce, the knowledge base is the curated set of documents, policies, and examples AI employees are grounded in when doing work — the source of truth behind their answers.",
    detail:
      "Grounding output in a maintained knowledge base is the main defense against hallucination in production. In mokaid, employees cite what they used, and gaps discovered in support or sales flow back as knowledge updates.",
    related: ["agent-memory"],
  },
  {
    slug: "hybrid-team",
    term: "Hybrid Team (Human + AI)",
    definition:
      "A hybrid team combines human employees and AI employees in one operating structure, with work routed to whichever teammate — human or AI — is best suited for it.",
    detail:
      "The dominant 2026 pattern is augmentation: AI employees absorb high-volume, well-defined work; humans keep judgment, relationships, and exceptions. Hybrid teams need shared visibility, which is precisely what a common office — physical or 3D — provides.",
    related: ["ai-workforce", "ai-employee"],
  },
  {
    slug: "observability",
    term: "AI Workforce Observability",
    definition:
      "AI workforce observability is the ability to see what every AI worker is doing, has done, and plans to do — through live status, logs, audit trails, and reporting.",
    detail:
      "You cannot manage what you cannot see. Dashboards give observability after the fact; mokaid's 3D office adds real-time, at-a-glance legibility on top of complete audit trails.",
    related: ["virtual-office", "approval-gate"],
  },
];
