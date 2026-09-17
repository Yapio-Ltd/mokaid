# Desktop UI regression check

## Scope and checks already completed

The visual changes cover the shared theme and controls, FeaturePage, ChatPanel,
ActionDialog, ActivityPanels, DriveNavigation, PreviewPanel and DeliveryView.
The map and renderer are unchanged. The page actions still come from the real
feature catalogue; workspace, notification and conversation counts remain bound
to their controllers.

- Qt 6.11 syntax parsing passed for the 13 updated QML files, plus the new
  MokaidDialog and MokaidMenu components.
- Controller calls and guards were inspected against OfficeController,
  FeatureController and ActivityController. Draft synchronization, history
  protection, offline send rejection, action context validation, destructive
  confirmation and workspace validation remain unchanged.
- Drive save/cancel transaction handling, overwrite confirmation, preview
  activity checks and WebEngine security settings remain unchanged.
- The agent catalogue has 11 selection actions, including a long transfer
  label. Selection buttons now fit their panel and occupy a scrollable area
  capped at 96 px, retaining room for record details.
- The three feature QML test fixtures now copy MokaidIcon.qml. The breadcrumb
  PlainText assertion checks the actual text item inside the button layout.

These are source and syntax checks, not a completed visual/runtime validation.

## One functional pass after the full build

Use the existing account without sending messages or submitting mutations.

1. Open the account menu with pointer and keyboard. Check selected/disabled
   entries, Escape dismissal, and preferences. In confirmation dialogs, Cancel
   must dismiss without accepting or discarding anything. Preserve
   Popup.NoAutoClose in the action/workspace forms.
2. Open an agent conversation, change between history and Current, then close
   and reopen it. Confirm names, history text, attachments and drafts remain
   visible; history stays read-only, Send stays disabled for empty/offline
   drafts, and merely opening the panel creates no draft.
3. Open Tasks or Agents, filter, select a record, explore a nested detail and
   return through the breadcrumbs. Check primary and selection actions remain
   reachable, including the long transfer action, without submitting them.
4. Open and cancel a form with a text field, multiline field and enum. Confirm
   prefilled values remain intact, the dropdown selects via pointer/keyboard,
   and closing does not submit. Run the existing feature QML tests for context
   invalidation, accessibility input, JSON preservation and keyboard navigation.
5. Browse Drive by Return on a folder, breadcrumbs and Back. Open the save
   chooser and cancel it. Check Trash navigation and return without deleting or
   restoring data. Run the prepared-download tests for transaction behavior.
6. Open a deliverable, switch retained tabs and return to the workspace. Cancel
   Reload/Replace confirmations and verify the retained view stays intact.
   Search and notification panels must close without stale modal focus.

## One visual pass

Inspect the normal desktop size and the supported minimum 1000 × 680. Include
the open chat panel, a record detail panel and one form/dropdown. Check:

- No map/background seam; the shared background remains #0b0b10.
- No text, toolbar, footer or popup overflow; long titles elide or wrap.
- Record details retain usable height with all agent actions present.
- Warm white/periwinkle text stays readable on the translucent navy surfaces.
- Hover, selection and keyboard focus are distinguishable; disabled actions
  remain visibly disabled.
- Names and message/record content containing markup display as plain text.

Limit follow-up inspection to correcting a concrete defect found in these two
passes. Primary builds and live application inspection are owned by root.
