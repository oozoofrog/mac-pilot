# Background input and foreground continuity for desktop act

Status: release contract for mac-computer-use 1.36.0. Scope: macOS desktop MCP `act` and `get_app_state`.

## Problem and evidence

An agent can alternate foreground input and state reads while completing a form. Restoring the previous app after every input repeatedly interrupts the desktop. A request for foreground input alone does not establish that the target ignored a background event.

Before 1.36.0 the [input policy](../../mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src/Modes.swift) defaulted to auto. The [operations guide](../../mac-computer-use/skills/mac-computer-use/references/operations.md) directs the caller to try background first. The [dispatcher](../../mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src/Accessibility.swift) accepted a foreground flag immediately in auto mode. It ran an action array locally and normally restored the previous app before returning state. Commit `045401f` introduced a specific exception for status popovers. The [daemon](../../mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src/Daemon.swift) retains that focus state per connection. Desktop focus is shared across connections.

## Architecture decision

Keep planning in the caller. Let the daemon enforce background-first admission and own the lifetime of foreground input. A chain is an explicit, temporary association between a connection and a target window. Start it only when foreground is needed. Background sequences already span decisions without retaining desktop focus. A larger action array works for predetermined steps but cannot select the next step from a newly opened dialog. An implicit delay before restoration would also hold the desktop after unrelated one-shot calls.

## Caller contract

The following fields extend the desktop tools. Preserve existing MCP content and error indicators. Expose continuation data as structured fields and in text for text-only clients. Keep app authorization checks on every call.

1. Call `act(app, actions)` in auto mode. Read the returned state. If a supported button opens the expected dialog, continue in the background using the dialog's current controls.
2. If a reversible action appears ineffective, inspect the same window again. Check an explicit expected result such as “the settings dialog is open.” Verify the target is still actionable. For a single background attempt, the daemon returns an opaque receipt bound to the connection, live process, window and attempted operation. An intervening read of that window may refresh element numbers.
3. To request foreground, send `foreground:true` with the receipt, the expected result and the observed result. The daemon MUST check that the attempt matches the same logical control and operation, that a subsequent observation exists and that the receipt is unused and current. A receipt proves that an attempt occurred. The caller remains responsible for interpreting application-specific results. If the target cannot be matched after a refresh, return a recoverable error before sending input. Reject a bare foreground request in auto with instructions to try the action in the background. Never silently execute a rejected request.
4. Optionally include `chain:"begin"` on the admitted foreground act. Return an opaque chain ID and expiry. Pass the ID on later acts and reads. The caller may inspect each result before choosing the next action. Related actions inside an admitted chain can use foreground without repeating the background trial. End with a control-only `act(app, chain:id, end:true)`. End MUST be idempotent for the owner. A foreground call without a chain retains one-shot restoration.

| User mode | Admission and continuity |
|---|---|
| auto | Default to background. Require the admission evidence above to enter foreground. |
| background | Reject foreground and foreground-chain requests. Honor a change to this mode during a chain before further input. |
| foreground | Honor the user's explicit choice without a background trial. Require an explicit begin to retain focus between calls. |

A successful event post, an unchanged tree, an unrelated browser permission error or elapsed time alone MUST NOT authorize replay. For a delayed save, submission, payment, deletion or an uncertain partial batch, the caller MUST reconcile the application state first. The daemon MUST NOT replay batches automatically. Report which steps completed, which failed and which were skipped. An uncertain external effect remains unknown. Never retry it on the strength of a receipt.

## Ownership and termination

- Admit one foreground owner across all connections. A competing foreground request MUST return busy before activation. Target-changing calls that could invalidate the owner's input MUST be prevented while owned. State reads may proceed. Numeric element references used in a chain MUST be tied to an observed snapshot. If another read invalidates that mapping, fail before input and request fresh state.
- Record the original app and window on acquisition. Validate the live target process and exact window after activation and before each real input, including after a wait. Permit a child sheet or dialog only when its relationship to the target can be established. A sibling window, ambiguous dialog or closed target ends ownership. A user switching away and back MUST invalidate the old chain. A stale ID MUST never reacquire focus.
- On end, cancellation, action failure, disconnect or expiry, release the owner. Restore the original window once only if it still exists and the automation still owns focus. Respect intervening user selection, including selection of another window in the same app. Release held mouse buttons or modifiers on interruption before accepting more input. Report incomplete restoration without retrying over a user's selection.
- The initial idle limit is 30 seconds after the last completed input. Observation alone MUST NOT renew it. Expire idle chains even if the client makes no further calls. Invalidate receipts on use, disconnect, a newer action on the target, target replacement or 30 seconds of age. These values are design defaults pending desktop measurements.
- Integrate the existing status-popover exception with the same ownership and cleanup rules. Preserve interaction until dismissal for existing popover clients subject to user intervention and disconnect. Define one restore operation when an explicit chain owns that popover.

## Acceptance checks for implementation

Run foreground checks serially under the [native check safety procedure](../native-check-safety.md). Use a disposable form with observable effect counters. Record ordered app and window focus changes, action results and final form state. Use two MCP clients for the contention case.

| Trigger | Required observable result |
|---|---|
| Auto, background-capable button, then field input | Correct dialog and value. MacPilot requests zero foreground activations. |
| Auto, first-call foreground or mismatched, expired or reused receipt | Action rejected before activation or input. Background-only mode rejects even a valid receipt. |
| Background-ignoring reversible control, fresh observation, admitted retry | Exactly one explicit foreground retry. Correct effect. No automatic retry. |
| One chain across three acts, state reads and a verified child sheet | Decisions use current state. One acquisition and one restoration when the original window differs. No intermediate return to the caller. |
| User selects another app or sibling window during a wait | No subsequent real input to that window. No forced restoration or reacquisition. |
| Second client requests foreground or refreshes the element mapping | Competing activation denied. Stale numeric targets cannot receive input. |
| Save completes late, or step two of three fails after step one commits | Committed effect occurs once. Results distinguish completed, failed and skipped steps. |
| End twice, disconnect, cancel, expire with reads only, close target, change to background | Owner released exactly once. No stale continuation. User-selected focus preserved. |
| Legacy one-shot foreground mode and status popover | One-shot restores after the call. Popover remains usable across observations and restores once at dismissal or disconnect if still owned. |

Before release, update the tool schema, errors and operations guide together. Explicitly document the behavior change for existing callers that request foreground immediately in auto. Qualify window identity, modal ancestry and user-intervention detection on the supported macOS versions. Where identity cannot be established, return state for inspection and stop foreground input.
