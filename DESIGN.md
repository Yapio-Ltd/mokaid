---
name: mokaid Agents workspace
description: The reference-led visual system for the web /agents route only.
colors:
  workforce-bg: "#090b13"
  shell-bg: "#090a11"
  workforce-surface: "#10111d"
  workforce-border: "#24263c"
  workforce-text: "#f2f2fc"
  workforce-secondary: "#b3bfdf"
  workforce-muted: "#9aa8cc"
  workforce-purple: "#a77bff"
  active-text: "#34edb0"
  idle-text: "#54c3ff"
  attention-text: "#f9be63"
  blocked-text: "#ff94a7"
  action-text: "#eee6ff"
typography:
  headline:
    fontSize: "clamp(26px, 2.32vw, 38px)"
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: "-0.012em"
  title:
    fontSize: "19px"
    fontWeight: 700
    letterSpacing: "-0.025em"
  body:
    fontSize: "13px"
  label:
    fontSize: "12px"
  eyebrow:
    fontSize: "12px"
    letterSpacing: "0.055em"
rounded:
  control: "10px"
  card: "12px"
  action: "14px"
  panel: "16px"
  sidebar: "17px"
  pill: "24px"
spacing:
  compact: "8px"
  control: "12px"
  card: "16px"
  workspace-gap: "18px"
  roomy: "24px"
components:
  button-create:
    textColor: "{colors.action-text}"
    rounded: "{rounded.action}"
    padding: "0 23px"
  button-detail-primary:
    rounded: "{rounded.control}"
    padding: "10px 14px"
  button-detail-secondary:
    backgroundColor: "#141623"
    textColor: "#f2efff"
    rounded: "{rounded.control}"
    padding: "10px 14px"
  input-agent-search:
    backgroundColor: "#0e101a"
    rounded: "{rounded.control}"
    padding: "0 10px"
    height: "41px"
  card-agent:
    backgroundColor: "#121521"
    rounded: "{rounded.card}"
    padding: "16px"
---

# Design System: mokaid Agents workspace

## Overview

**Creative North Star: "The referenced AI workforce workspace"**

This document records the implemented web `/agents` surface. Its visual authority is the user-supplied `ChatGPT Image Sep 16, 2026, 10_36_57 PM.png`: dark navy surfaces, purple outlines and restrained glows, an inset sidebar, a searchable roster, a right-side agent inspector, and bottom aggregate metrics. The reference establishes presentation; the user's persisted agents establish content.

Scope is intentionally limited to this route and its conditional shell. Other web routes, authentication, account behavior, backend contracts, and native interfaces retain their existing implementations. The Agents shell uses locally hosted Manrope, with Inter and sans-serif fallbacks.

**Key Characteristics:**

- Dense, legible operational data on layered dark surfaces.
- Purple borders and light identify selection and primary actions.
- The roster and inspector show the user's real agents and accessible records.
- Responsive stacking preserves the same actions and information.

## Colors

Purple and blue accents sit over low-contrast navy surfaces; status colors communicate the actual state alongside text.

### Primary

- **Workforce purple:** selection, focus, actions, and subtle light around active controls.
- **Action text:** pale lavender for the creation action.

### Secondary

- **Active text:** green for active state.
- **Idle text:** blue for idle state.
- **Attention text:** amber for training, waiting, and busy state.
- **Blocked text:** pink for blocked state.

### Neutral

- **Workforce background / shell background:** the page palette anchor and the shell's actual gradient base, respectively.
- **Workforce surface / border:** layered containers and quiet separation.
- **Workforce text:** primary content.
- **Workforce secondary / muted:** descriptions, metadata, and supporting labels.

**The State Meaning Rule.** A colored dot must accompany a state label. Browser “Online” describes the browser network connection; it does not certify backend or integration health.

## Typography

Use the route's `"Workforce Manrope", Inter, sans-serif` font stack. The variable font is served from `apps/web/public/fonts/Manrope.ttf`, with weights 200–800 and `font-display: swap`; its license is retained in `OFL-Manrope.txt` beside the font. The font-family override belongs to `.wf-shell`. Preserve compact sizes and tabular numerals for scanning and comparing data.

- **Headline:** the page title uses the responsive headline token; it becomes 29px at widths up to 700px.
- **Title:** the selected agent's name uses the title token and wraps when necessary.
- **Body / label:** roster content and inspector controls use the body and label roles; subordinate roles, skills, and metadata use the observed 9–11px scale.
- **Eyebrow:** the uppercase page label uses the eyebrow token. Table headings are compact uppercase labels with restrained tracking.
- **Metrics:** summary values are 22px, reducing to 20px at the compact desktop breakpoint. Inspector values are 23px, reducing to 21px on small phones.

## Layout

The desktop shell uses an inset sidebar with a rounded border and an 84px top bar. The sidebar is 267px wide, narrows at 1450px and 1100px, and supports a 76px collapsed state. At viewport heights up to 900px and widths above 760px, navigation and promotional spacing condense to retain the profile area. The top bar retains the existing search, notification, sound, and account implementations. Search supports Command/Ctrl+K.

The main workspace pairs a flexible roster with a right inspector occupying at least 350px and ordinarily 37% of the available width, separated by the workspace-gap token. The desktop workspace height is `max(640px, calc(100dvh - 207px))`, with its single grid row allowed to shrink using `minmax(0, 1fr)`. The roster content scrolls within that bounded height while the toolbar and bottom aggregate cards retain their space. Closing the inspector returns that space to the roster.

At 1200px and below, the inspector stacks beneath the roster; selecting an agent focuses the panel and scrolls it into view. Closing the panel restores focus to that agent's identity control. At 760px and below, navigation becomes a dismissible overlay and the top bar condenses. At 700px and below, heading and toolbar controls stack, aggregate metrics use two columns, and agent cards use one column. The list keeps a 690px minimum table width inside its own horizontal scroll container. At 520px and below, the inspector header wraps and metadata uses one column of label/value rows, including last activity. Inspector spacing tightens further at 480px.

The inspector has a fixed header and action footer with independently scrollable tab content. Its instructions section also scrolls when long. Keep focus indicators visible and preserve reduced-motion behavior when changing responsive interactions.

## Elevation & Depth

Tonal layering and thin borders do most of the structural work. Gradients add a faint purple cast to navy containers. Active navigation, the creation action, and the selected inspector tab use local glows; menus use a dark floating shadow. The generated transparent `workforce-energy-orb.png` decorates the sidebar promotion and account-menu control. Its image-generation provenance is retained in `apps/web/public/branding/workforce-energy-orb.json`. The orb carries no metric, agent identity, or availability meaning.

Exact shadow, gradient, focus, and transition recipes are recorded in `.impeccable/design.json` and remain sourced from the route stylesheets. Control transitions are short (150–180ms); the loading placeholder fades over 1.7 seconds. Reduced-motion preferences disable or effectively remove these animations and smooth scrolling.

## Shapes

Use rounded corners throughout this route, including environments whose global styles support a different corner shape. Controls and cards use the smaller radius tokens, the inspector and sidebar use the larger tokens, and search/connection controls in the top bar use pill shapes. Avatars and status dots remain circular. Selection is a border and surface change, not a change in content or dimensions.

## Components

### Buttons

The creation button uses a dark purple-to-blue fill, a violet-to-blue border, and a restrained inset glow. Inspector primary actions use a brighter purple gradient. Inspector secondary actions use a dark filled surface. Hover changes color and border; keyboard focus uses a visible lavender outline. The roster, grid, and inspector share `WorkforceAgentActions` for existing overview, chat, edit, and training routes. “Test agent” is disabled for human-linked agents in both the inspector and the shared action menu.

### Chips and filters

Status chips combine a text label and colored dot. Skills use compact, subdued rectangular tags; long roster tags truncate, while the inspector allows skill labels to wrap. The active filter uses purple edging, with real counts beside its label. The Active filter includes agents whose persisted state is active or busy, while each agent retains its exact state label.

### Cards and roster

List and grid modes are alternate views of the same fetched agents. Both preserve identity, state, selection, and existing actions. The selected row/card gains a purple border and cooler surface. Search matches name, role, department, and skills. Empty, loading, failed-request, and no-match states occupy the same roster area with appropriate recovery actions.

### Inputs

The roster search is a compact rounded field with a leading search icon and a purple focus border. The top search remains the existing application search in a wider pill-shaped field. Preserve accessible names and native input behavior.

### Navigation

The inset sidebar retains existing route destinations, workspace selection, the signed-in user's profile, and workspace/account options. Agents is highlighted with a purple border, glow, and trailing light. On mobile, opening the sidebar focuses its close button, Tab cycles within its visible controls, and closing restores prior focus. The sidebar closes through its close button, scrim, Escape, or navigation. Open menus retain their own keyboard handling; Escape in the sidebar preserves the selected agent underneath.

### Agent inspector

Overview, Tasks, Skills, Knowledge, and Settings are functional tabs for the selected real agent. The panel contains persisted identity and instructions, performance, assigned tasks, mission totals, skills, workspace access, and granted integrations. Use the actual grant list intersected with installed integrations, and show each installation's reported state. The footer opens existing chat and edit flows. Task actions open the existing task inspector; Knowledge uses the existing memories component.

The header's availability dropdown displays the persisted status and exposes “AI assistance enabled”, which saves `ai_enabled` through `useUpdateAgent`. It does not overwrite the status label or manufacture presence. The checkbox is disabled for human-linked agents and while saving; a failed save produces an error toast. The menu also links to existing agent settings.

### Agent portraits

`WorkforceAgentPortrait` uses seven existing GLB-rendered static portraits, defaulting to 60px in roster rows and 74px in the inspector. Compact roster layouts use 50px; the inspector portrait becomes 60px at widths up to 520px. Each circular portrait sits on indigo with a thin violet border. The source GLB hashes and image paths are recorded in `apps/web/public/branding/agent-portraits/provenance.json`.

Match the agent's actual `avatar_cdn_path` against the exact known hashed asset URL through the existing CDN resolver. An unassigned default avatar resolves through that same logic. Never select a portrait by agent name, role, or an approximate filename. Unknown, custom, human, or unresolved assigned assets retain `AgentAvatar`; failed portrait loads also fall back to it.

### Workforce metrics

The bottom cards summarize the entire fetched roster, independent of filters: “Total agents”, “Active now” (active/busy agents), “Missions completed”, and “Avg. performance” (the average of available performance scores). The performance card shows the number of rated agents in compact supporting text. This month's additions come from creation timestamps. Keep this copy compact so five full roster rows and the aggregate cards fit the reference desktop composition. Missing scores display an em dash and explicit supporting text. Task request failure is disclosed without replacing unavailable task counts with a fabricated zero.

Tiny task sparklines and completion bars count loaded Task records whose status is completed and whose valid `completed_at` falls within the latest 14 UTC calendar days, including today. Future or missing completion dates are excluded; `updated_at` is never substituted. Active-task bars show each loaded task's current persisted `progress_percent`, with up to eight bars, excluding completed and canceled tasks. The charts disclose their data in accessible labels and distinguish unavailable records from a loaded empty set.

**The Data Meaning Rule.** `performance_score` is a current combined progression score, labeled Performance and represented by a static segmented meter. Never label it success rate or imply a performance history. The task-completion sparkline beside a roster score and the bars beneath Missions completed describe dated Task activity; they do not graph performance or lifetime mission totals. `missions_completed` remains Missions completed. Only actual dated task records form history; progress bars represent current scalar values.

## Do's and Don'ts

### Do:

- **Do** apply this visual system only to the web `/agents` route and its conditional shell.
- **Do** use the supplied reference for composition while populating it from the user's actual records.
- **Do** preserve real identities, existing routes, account actions, backend contracts, and native interfaces.
- **Do** retain loading, error, missing-data, keyboard-focus, and reduced-motion states.
- **Do** preserve focus transfer and restoration for mobile navigation and the stacked inspector, including the sidebar's Tab cycle and Escape ownership.
- **Do** distinguish performance scores, assigned tasks, and completed missions in every label and aggregate.
- **Do** preserve exact avatar source matching, asset provenance, and the existing fallback renderer.

### Don't:

- **Don't** expand this route-specific design into unrelated interfaces without a separate request.
- **Don't** insert reference-image names, mock agents, fabricated connections, or decorative statistics into live data.
- **Don't** draw trend lines or sparklines without historical data.
- **Don't** present browser connectivity as server or integration health.
- **Don't** silently turn unavailable task data into zero activity.

## Native application scope

The desktop-wide redesign requested on September 17, 2026 is documented separately in [apps/desktop/DESIGN.md](apps/desktop/DESIGN.md). The web route scope described above does not restrict that explicitly requested native work. Native visuals are implemented in Qt Quick/QML and must be verified in the rebuilt desktop executable.
