# NFS Notes — Tech Assist: Plan for Approval

Status: **REVISION 2. Approved 2026-10-10. M1–M10 done and reviewed (see `docs/handoff/`). Business wording is placeholder text (user fills in later). Still open: emulation-key check on a work PC; M3–M10 visual checklists. Next: M11.**
Date: 2026-10-10 · Owner (planning/review): Opus · Implementation: Sonnet subagent, one milestone at a time, with a written handoff per milestone.

---

## 1. What is in the project today

| Path | Contents | Plan |
|---|---|---|
| `Gui visual Library/` | **AxAHK / AxGui v1.05**: 71 `.ahk` files (~11.5k lines in `lib/`), 60+ component packs, 20 stylesheets, docs, examples. No AxStudio folder (the docs mention it, but it isn't here). | Treat as a vendored dependency and don't edit it. Include it in place. |
| Everything else | Nothing. No existing app code, config or assets. | New files go beside the library (see §4). |

What AxGui means for this design:

- **The UI is HTML/CSS in an embedded IE11 (Trident/MSHTML) control**, driven from AHK over COM. There's no JavaScript in apps. Themes are real stylesheets, so full live re-theming *is* possible, which is better than native `Gui`.
- Useful built-ins: page rail (`AddPage`) for navigation, `AddStepper` (wizard steps), `AddSegmented`, `AddChip`, `AddCard`, `AddRow`, `AddDataView`, `AddStat`, `Popover(..., {On:"hover", Build})` (rebuilt on every open, so it can serve as the **live call-count tooltip**), `Toast`, in-window `Confirm`/`Dialog`, `AskBeforeClose`, `SetTheme/SetAccent/SetTint/SetExtraCss`.
- `AxJson.ahk` is included, so **JSON config needs no new dependency.** Two caveats: `null` parses as `""` and booleans parse as `1/0`, so the schema never relies on `null`.
- IE11 CSS limits: no CSS variables, grid or `gap`. Theme values are generated into CSS text from AHK.
- On first run the library writes an HKCU registry value (`FEATURE_BROWSER_EMULATION`) so the control runs in IE11 mode. **Risk:** locked-down corporate PCs may block it (see §8).

## 2. Decisions already made (from your answers)

| Topic | Decision |
|---|---|
| Static IP gateway | **Gateway = entered IP + 1**, valid only if the entered IP is a usable host and IP+1 is a usable host (not the broadcast). Otherwise show a clear error and let the agent type the gateway manually. |
| Config location | The program and admin-managed config live in a **shared OneDrive folder**: config is `config\config.json` next to `NFSNotes.ahk`. Each user keeps a **local cached copy** in case the shared file is broken or half-synced. Everything per user (settings, themes, history, stats, logs) goes in **`Documents\NotesForNFS`** (decided 2026-10-10). The new app ignores the old script's files there. |
| Categories per call | **Several categories per call**, combined into one note. |
| What counts a call | **Only the provider's "new call" event** (your UIA structure-changed event) increments the count. It also resets the session. The agent's **Clear All** resets without counting. Until the UIA event exists, a mock/dev button fires the same event. |
| Uncategorized calls | A new-call event with no category used counts as **Uncategorized**, so the total always equals the number of events counted. |
| Trouble Call supervisor | The tech must say they've spoken to their supervisor and give the supervisor's name. If they haven't, the workflow **stops**: a banner tells the agent the tech must contact their supervisor before calling back, and the remaining Not Done steps are locked. |
| Clearing notes → History | Every clear (new-call event **or** Clear All) first saves the call to **History**, as long as anything was entered. History is a pop-out list; **double-clicking an entry loads all of it back** (context snapshot, every category's answers, and the note text including agent edits). |
| Tech name format | AppBar gives `First Last`. The first name is the first word. |
| Equipment actions | **Added, Removed, Swapped** only. |
| Environment | AutoHotkey **2.0.19**, run as plain `.ahk` (no exe). Registry writes allowed. The shared config folder defaults to `config\` beside the program (the OneDrive folder); `nfsnotes.ini` can override it. |
| Branding | Spectrum brand **approved** for this internal tool (colours and logo). |

## 3. Remaining defaults (go ahead unless you object)

The brief's requirements (sections 1–13) stand, along with the decisions in §2. These smaller defaults apply unless you say otherwise:

1. **Duplicate new-call events.** Repeat events within **3 s** are ignored. If the event carries a job number, an event with an unchanged job number is also ignored. The window is admin-configurable.
2. **First-name rule.** Trim, then take the first word. If the name is all caps or all lowercase, title-case it (`JORDAN SMITH` → `Jordan`); otherwise keep the casing as given. The rule is unit-tested and the admin can't change it.
3. **Unavailable vs empty in the note.** An unavailable value prints `[not available]` (admin-configurable text). A legitimately empty value prints nothing. The context card shows each field's status (Live / Mock / Manual / Unavailable / Stale / Empty / From history).
4. **Billing.** Actions are *Added, Removed, Changed*. Each entry has an outcome: *Completed / Requested — not yet completed / Unable to complete*. The note says "completed" only when the agent picks Completed.
5. **Equipment swap note** reads like "Swapped Router." An optional detail box holds anything extra. The app never invents serials, models or quantities.
6. **Trouble Call stop.** When the tech hasn't spoken to their supervisor, the Not Done note is limited to: reason, order type, and "Tech has not contacted supervisor; advised tech to contact supervisor before calling back." Nothing else from Not Done gets into the note.
7. **Static pinging note.** After a ping, the outcome is pre-filled from the real result (Reply received / No reply). The agent must confirm it.
8. **Supported prefixes** for the gateway calculation are **/8–/30**. A dotted mask is also accepted.
9. **Ping defaults.** 1000 ms timeout, "Ping" = 4 attempts, "Ping Until Success" = one attempt per second capped at 10 minutes, cancellable at any time.
10. **History storage and retention.** History is saved **per user** in `Documents\NotesForNFS\history\YYYY-MM-DD.json`, never in the shared folder and never in the diagnostic log. It's kept **14 days** (admin-configurable, 1–90) and older days are deleted at startup. Because it holds technician names, job numbers and addresses, it stays in the agent's own Documents.
11. **Loading from history** while the current call has unsaved content asks first ("Replace current call? It will be saved to History first"). Loading never counts a call. Fields loaded from history show as **From history**, never Live.
12. **Agent identity for stats** = Windows `A_UserName`. Stats are local per PC and labelled "Local count — not AppBar data".
13. **Spectrum look.** Spectrum blue `#0099D8` accent on navy `#003057` brand band, using the Microsoft 365-like `win365` look as a base, in light and dark. The logo is used only if you put an approved logo file in `assets\` (the app will not fetch one from the internet).

### Registry (your question)

The app needs **one** registry value, written by the AxAHK library to your user hive (no admin rights needed):

```
HKEY_CURRENT_USER\Software\Microsoft\Internet Explorer\Main\FeatureControl\FEATURE_BROWSER_EMULATION
  value name: AutoHotkey64.exe   (the program that runs the .ahk)
  type: REG_DWORD   data: 11001
```

This value makes Windows' built-in HTML engine render the app's window in IE11 standards mode instead of the old IE7 mode. Without it, the modern styling breaks. It affects only programs named `AutoHotkey64.exe` (all your AutoHotkey v2 scripts), and only how their embedded HTML views render. It doesn't touch Edge or Chrome. The library writes it only if it is missing or different. If it's ever blocked, the app detects the old render mode and shows a clear message.

The library has a second, optional switch (`FEATURE_GPU_RENDERING`, for a faster first paint). It is **not used** unless you ask for it.

## 4. Architecture

### 4.1 Directory structure

```
NotesAHK 3.0\
  NFSNotes.ahk                 main app entry (thin: includes + App.Run())
  NFSAdmin.ahk                 admin companion entry
  nfsnotes.ini                 bootstrap: optional config-folder override, log level, dev mode
  Gui visual Library\          AxGui (vendored, unchanged)
  lib\UIA\                     UIA-v2 (added only at the AppBar milestone)
  src\
    Core\     App.ahk          composition root: builds services, wires events
              Log.ahk          rotating diagnostic log, redacts names/addresses/IDs
              Util.ahk         small shared helpers (string, time, file atomic write)
    Config\   Schema.ahk       schema version, validator, migrations (shared by both apps)
              Defaults.ahk     built-in default config (source of truth for "Restore defaults")
              ConfigStore.ahk  load shared → validate → cache; fallbacks; atomic save + backup + lock
              Settings.ahk     per-user prefs in Documents\NotesForNFS\settings.json
    Context\  CallContext.ahk  field model with status per field
              Provider.ahk     provider contract + registry
              MockProvider.ahk mock data + dev controls (missing/stale/new-call)
              AppBarProvider.ahk  UIA-v2 adapter (stub until AppBar is available)
    Call\     CallSession.ahk  current call: per-category answers, entries, note edit state; Snapshot()/Restore()
              CallStats.ahk    daily per-category counts, debounce, persistence
              History.ahk      save on clear, list, load, retention cleanup (Documents\NotesForNFS only)
    Workflow\ Engine.ahk       data-driven steps/conditions/validation, answer retention
    Notes\    Composer.ahk     fragments + placeholders + dedupe + formatting + template
              Clipboard.ahk    copy with verification and retry
    Net\      Ipv4.ahk         parse/validate, mask↔prefix, network/broadcast, gateway rule
              Pinger.ahk       async ICMP (IcmpSendEcho2 + event, polled by SetTimer)
    UI\       Theme.ahk        settings → AxGui stylesheet/theme/accent/tint/extra CSS
              MainWindow.ahk   shell: title bar, context card, rail, notes panel
              Views\StepsView.ahk   generic renderer for "steps" categories (Not Done, Close Job)
              Views\ItemsView.ahk   generic renderer for "items" categories (Equipment, Billing)
              Views\StaticView.ahk  Static notes + IP utility + ping console
              Views\HistoryPanel.ahk  pop-out history list (search, double-click to load)
              Views\SettingsView.ahk
              Views\DevPanel.ahk    mock/dev controls (hidden unless dev mode)
    Admin\    AdminWindow.ahk  category/option/fragment/template/theme editors, preview, import/export
  themes\spectrum.css          /* @extends win365 */ Spectrum-inspired look
  config\config.json           admin-managed config (shared via OneDrive)
  config\config.default.json   exported copy of Defaults (reference; app does not need it to start)
  tests\  RunTests.ahk  TestLib.ahk  Test*.ahk   (headless logic tests → tests\results.txt)
  docs\   PLAN.md  ARCHITECTURE.md  TESTPLAN.md  SETUP.md  CHECKLIST.md
```

### 4.2 Dependencies between modules (one direction only)

```
UI  ──▶  App (composition root)  ──▶  Workflow.Engine ─▶ Notes.Composer
 │                                │                       ▲
 │                                ├──▶ Call.Session ──────┘
 │                                ├──▶ Call.Stats
 │                                ├──▶ Context.Provider (Mock | AppBar)
 │                                ├──▶ Net.Ipv4, Net.Pinger
 │                                └──▶ Config.Store/Settings ─▶ Config.Schema
 └── reads only: Theme, Session state, Context snapshot
Everything ─▶ Core.Log, Core.Util
```

- Logic modules (`Config`, `Context`, `Call`, `Workflow`, `Notes`, `Net`) **never include UI or AxGui**, so they're testable headless.
- There's no global mutable state. `App` owns one instance of each service and passes it to whatever needs it.
- The Admin app reuses `Config\*`, `Workflow\Engine`, `Notes\Composer` and `UI\Theme` (for the live note preview), and nothing from `MainWindow`.

## 5. Contracts

### 5.1 Context (what any provider returns)

```ahk
; CallContext.Fields is a Map of fieldId -> ContextField
class ContextField {
    Value     ; string; "" only when Status = "empty"
    Status    ; "live" | "mock" | "manual" | "unavailable" | "stale" | "empty" | "history"
    Source    ; "mock", "appbar:uia", "agent"
    ReadAt    ; A_Now when read
}
; required field ids: techName, techId, address, jobNumber, workOrder
; providers may add more; extra fields are shown only if config lists them
```

- An agent may type a value over an unavailable field. It then shows as **Manual** and is never presented as live.
- When the provider is the mock, a permanent **MOCK DATA** badge is shown in the title bar.

### 5.2 Provider interface

```ahk
class ContextProvider {           ; MockProvider and AppBarProvider implement this
    Kind => "mock" | "live"
    Start() / Stop()
    GetContext() => CallContext    ; never throws; failures become field Status
    Health() => {Ok, Message}      ; shown as a small status dot
    OnContextChanged(fn)           ; fn(ctx) when values update
    OnNewCall(fn)                  ; fn(ctx) — the counted call boundary (your structure-changed event)
}
```

The UIA adapter keeps discovery, polling, staleness checks and retry inside the provider. The workflow engine and note composer never see UIA.

### 5.3 Workflow model (config-driven)

Category `kind` is one of:

- **`steps`**: an ordered list of steps. Each step has `id`, `label`, `type` (`choice` | `yesno` | `text` | `group`), `options[]` (`id`, `label`, `fragment`), `fields[]` (`id`, `label`, `required`, `requiredWhen`), `when` (a condition), and `fragment` (a template with placeholders such as `{supervisorName}`). Used by Not Done and Close Job.
- **`items`**: repeating line items `{action, item, qty?, outcome?, details?}` with configured lists of actions, items and outcomes, and a fragment template per action. Used by Equipment and Billing.
- **`static`**: the code-owned Static view. Config controls its option lists and fragments only.

Conditions are kept deliberately simple: `{"step": "orderType", "in": ["pwo", "tc"]}`, combinable with `all`/`any`. No expressions or scripting.

Compatibility rules that business hasn't confirmed are declared as **`flags`** (show a warning, never block). Answers are kept when the agent moves back and forth between steps or categories.

Not Done steps as configured: `reason` → `orderType` → `supervisorPwo` (when PWO: the agent contacts the supervisor; supervisor name and reason for reschedule both required) | `supervisorTc` (when TC: "Has the tech spoken with their supervisor?" **Yes** → supervisor name required; **No** → `stop` with the banner and limited note, per §3.6) → `contact` (choice + details) → `outcome`. SRO skips the supervisor step.

A step can declare a **`stop`** result: the workflow locks the steps after it and shows the configured message. This is how the Trouble Call rule is expressed, and admins can reuse it.

### 5.4 Note generation

```
Compose(ctx, session, config) => {Text, Warnings[]}
```

1. For each category used (in config order), turn its answers and entries into fragments, fill placeholders, **drop exact duplicates**, and normalise spacing, capitalisation and end punctuation.
2. Join fragments within a category with `fragmentJoiner` (default `" "`), and categories with `categoryJoiner` (default newline).
3. Render the template lines (default below) with `{tech.firstName}`, `{tech.id}`, `{job.number}`, `{notes}`, etc. Values are inserted exactly as given (no trimming of IDs beyond surrounding whitespace).

```
Tech name: {tech.firstName}
Tech ID: {tech.id}
Job Number: {job.number}
Notes: {notes}
```

**History:** before any clear (new-call event or Clear All), `CallSession.Snapshot()` writes the whole call to History if anything was entered: context snapshot, every answer and entry, the note text, whether it was agent-edited, the categories used and the time. `Restore()` loads it all back.

**Edit safety:** the notes box is editable. Once the agent edits it, the box is "agent-edited": later workflow changes **don't overwrite it**. A bar instead offers "Regenerate (replaces your edits)", which asks for confirmation. Clear All asks for confirmation ("Clear this call? It will be saved to History"). Nothing is ever cleared without first being saved to History.

**Copy Notes:** writes to the clipboard, waits for `ClipWait`, reads the clipboard back to verify, retries once, then shows a success toast or an actionable error ("Clipboard is in use by another app — try again"). Copying never counts a call.

### 5.5 Configuration schema (JSON, shared by both apps)

```json
{
  "schemaVersion": 1,
  "revision": 1, "updatedAt": "2026-10-10T17:00:00", "updatedBy": "admin",
  "noteTemplate": { "lines": ["Tech name: {tech.firstName}", "..."],
                    "unavailableText": "[not available]",
                    "fragmentJoiner": " ", "categoryJoiner": "\n",
                    "sentenceCase": true, "endPunctuation": "." },
  "contextFields": [ {"id":"techName","label":"Technician"}, "..."],
  "categories": [ {"id":"notDone","label":"Not Done","icon":"E711","enabled":true,
                   "system":true,"kind":"steps","steps":[ ... ]}, "..." ],
  "themes": { "default":"spectrum-light",
              "presets":[{"id":"spectrum-light","label":"Spectrum","sheet":"spectrum","mode":"light","accent":"#0099D8"}] },
  "ping": { "timeoutMs":1000, "attempts":4, "intervalMs":1000, "untilSuccessMaxMin":10 },
  "callTracking": { "newCallDebounceMs":3000 }
}
```

**Loading:** shared file → validate → write the local cache → use it. If the shared file is unreachable or invalid, use the cache (with a warning chip), then built-in defaults (with a warning chip). A config change is applied **between calls, never mid-call**.

**Saving (Admin):** take a lock file (`config.lock`, user + time, stale after 30 min) → validate → write `config.json.tmp` → re-read and parse it → back up the current file to `backups\config-YYYYMMDD-HHMMSS.json` (keep the last 20) → replace the file. On any failure the original stays untouched.

**Configurable vs code-only:**

| Admin can change | Stays in code |
|---|---|
| Category labels, icons, order, enabled | IPv4 maths and gateway rule |
| Options, steps, conditions (simple), required flags | Ping mechanism and its bounds |
| Note fragments, placeholders, template lines, joiners | Call counting, debounce semantics |
| New `steps`/`items` categories | Provider/UIA logic, validation rules |
| Theme presets, default look | Clipboard handling, logging/redaction |
| Ping timings within code-enforced limits | Schema migrations |

"System" categories (the five built-ins) can be renamed, disabled or edited, but deleting one requires an explicit warning and confirmation. Required steps such as Not Done `reason` can't be removed. That is enforced by the validator in both apps.

## 6. Main window layout (about 820×680, resizable, optional always-on-top)

```
┌ NFS Notes ·  [MOCK DATA]  · config: shared r12 ●          [☾] [📌] [–][□][×] ┐
│ ┌ Technician ─────────────────────────────┐ ┌ Calls today ┐                 │
│ │ Name  Jordan Smith    ID  T12345        │ │     7       │ ← hover: per-    │
│ │ Job   88412   WO 55-2231                │ │ local count │   category +     │
│ │ Addr  123 Example St …   status dots    │ └─────────────┘   total popover  │
│ └─────────────────────────────────────────┘                                  │
├──────────┬──────────────────────────────────────────────────────────────────┤
│ Not Done │  [category view: stepper / item list / static utility]          │
│ Equipment│                                                                  │
│ Billing  │                                                                  │
│ Static   │                                                                  │
│ Close Job│                                                                  │
│ ─────    ├──────────────────────────────────────────────────────────────────┤
│ Settings │ Notes (editable)                      [History ▾] [Clear All]   │
│          │ Tech name: Jordan …                               [ Copy Notes ] │
├──────────┴──────────────────────────────────────────────────────────────────┤
│ History (shown when toggled: window grows downward, like your old script)   │
│ [search: name / job / category ]                         Today ▾  14 days    │
│ Time   Tech     Job     Categories          Note preview                     │
│ 14:02  Jordan   88412   Not Done, Billing   Not Done - Customer not home…    │
│ 13:47  Casey    88390   Equipment           Swapped Router. …                │
│                                    double-click a row → loads the whole call │
└─────────────────────────────────────────────────────────────────────────────┘
```

Rail items show a small dot when that category has answers in the current call.

**History panel.** This keeps your proven pattern: a **History** button grows the window downward to reveal the list, and pressing it again shrinks it back. The improvements are a search box, a day selector, a note-preview column, and a preview pop-over on hover, so you can check a call before loading it. The window remembers whether History was open. If the bottom of the screen is too close, the window grows upward instead so it never goes off-screen.

**M1 spike check:** confirm that AxGui can keep a notes panel visible across all pages. Fallback: the panel is rendered on each page, bound to the same session state.

## 7. Static IP utility behaviour

- **IP field** accepts `a.b.c.d` or `a.b.c.d/p` (and `a.b.c.d/255.255.255.252`). On Enter, blur or paste, it splits into IP and prefix, then calculates the gateway.
- **Validation:** exactly 4 decimal octets, each 0–255, no leading zeros. Reject 0.x, 127.x and 224+ (multicast/reserved).
- **Gateway rule (IP+1):** the IP must not be the network or broadcast address, and IP+1 must be less than the broadcast address. Required test: `1.1.1.1/30` → IP `1.1.1.1`, prefix `30`, gateway `1.1.1.2`.
- More examples: `1.1.1.2/30` → error (IP+1 = .3 = broadcast). `1.1.1.0/30` → error (network address). `1.1.1.9/29` → `.10`. `/31`, `/32` → "unsupported for auto-gateway".
- **Ping** uses the Windows ICMP API (`IcmpSendEcho2` with an event handle, checked by a 50 ms `SetTimer`). There's no shell command at all, so no injection risk and no parsing of localised `ping.exe` text.
- Success is reported **only** when a reply comes back with status `IP_SUCCESS` from the target address. Live console lines, attempt count, last result, elapsed time and status are shown. Cancel works at any point.
- **Fallback (if the API proves unreliable):** hidden `ping.exe -n 1` per attempt, using a validated IP only, with output parsed for `TTL=` *and* the target address. Plain exit codes aren't trusted, because "Destination host unreachable" can still return 0.
- The UI states plainly that **no reply ≠ device offline** (ICMP may be filtered).

## 8. Dependencies, risks, limitations

| Item | Notes / mitigation |
|---|---|
| AutoHotkey 2.0.19 | Confirmed. Run as `.ahk`. All code targets 2.0 syntax (no 2.1-alpha features). |
| AxGui 1.05 (present) | Pin this copy. Upgrades are a separate task. |
| UIA-v2 (Descolada) | Added only at the AppBar milestone. No other dependencies proposed. |
| MSHTML / IE11 engine | Still ships with Windows 10/11, but it is legacy tech. **Risk:** group policy may block the HKCU emulation key or MSHTML. Registry write confirmed allowed (see §3). Still check on a real work PC in M1. |
| History file privacy | Contains tech names, jobs and addresses: stored only in the user's `Documents\NotesForNFS`, auto-pruned, never logged or written to the shared folder. If work policy syncs Documents to OneDrive, it stays in the user's own account. |
| Shared OneDrive folder | OneDrive keeps a local synced copy, so the config is normally always readable. The lock file can't stop two admins on **different PCs** from saving at once, because OneDrive syncs the lock too slowly. The revision check catches it after sync, and the Admin app (M10) warns about OneDrive conflict copies (`config-<PC>.json`). Replace isn't truly atomic (temp + verify + backup). |
| Duplicate/bursty UIA events | Debounce + job-number change check (§3.4). |
| Clipboard contention | Verify + retry + clear message. |
| **Testing limits** | Claude runs on this Windows PC and can run AutoHotkey 2.0.19 (`C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe`) directly. Logic tests in `tests\RunTests.ahk` are run headless by Claude, which writes `tests\results.txt`. GUI checks (looking at the window) need screen control with your OK, or you run the manual checklist. Nothing is reported as passed unless it was actually run. |
| IE11 CSS | No CSS variables or grid. Theme CSS is generated from AHK. |

## 9. Milestones and acceptance tests

Each milestone ends with: a runnable app, logic tests run by `RunTests.ahk`, a manual GUI checklist, a handoff note (changed files, results, known issues), and an Opus review against this plan.

| # | Milestone | Acceptance (summary) |
|---|---|---|
| M1 | Skeleton + AxGui spike: entry scripts, logging, main shell with rail pages, persistent notes-panel check, hover popover check, test harness | App starts, rail switches pages, popover shows on hover, log written without personal data, `RunTests.ahk` produces results.txt, emulation key works on a work PC |
| M2 | Config: schema, defaults, store (shared → cache → defaults), atomic save, backup, lock, per-user settings | Missing/malformed/old-version/unreachable config each loads the right fallback with a visible chip. Save interrupted → original intact. Backups rotate. |
| M3 | Context contract, mock provider, dev panel, CallSession, CallStats (debounce, per-category, Uncategorized, persistence, popover) | Mock badge always shown. Missing/stale/empty fields display distinctly. New-call event counts once (burst of 5 in 1 s → 1). Event with no category → Uncategorized. Clear All doesn't count. Stats survive restart and roll over at midnight. |
| M4 | Note composer, clipboard, notes panel (edit lock, regenerate confirm), **History** (save on clear, pop-out panel, search, double-click load, retention) | Both clear paths save to History. An empty call isn't saved. Double-click restores answers, entries, context (as "From history") and edited note exactly. Loading over unsaved work asks first. Loading doesn't count. Files older than 14 days are pruned. Window grows and shrinks without going off-screen. First-name rule tests (10+ cases). Template exact output. Duplicate fragments dropped. Unavailable text appears. Edits never overwritten without confirm. Clipboard content verified. |
| M5 | Workflow engine + Not Done + Close Job | Every branch: 4 reasons × 3 order types × TC yes/no × 4 contact × 4 outcomes. TC "No" stops the workflow, locks later steps, and produces the limited note. PWO and TC-yes require the supervisor name. Required-field validation. SRO skips the supervisor step. Answers retained when navigating. Unconfirmed rules flagged, not blocked. |
| M6 | Equipment (Added/Removed/Swapped) + Billing (items) | Multiple entries, edit/remove an entry, qty optional, no invented values, billing "completed" only when chosen. Combined note with Not Done. |
| M7 | Static: IPv4 lib + utility + scripted/pinging notes | Required `1.1.1.1/30` case plus a full valid/invalid table (§7). Mask input works. Errors are actionable. |
| M8 | Async pinger | Success (real gateway/127.0.0.1-style local check), failure (unused IP), cancel mid-run, until-success cap, UI stays responsive (can type and switch pages during a ping), no leftover handles. |
| M9 | Settings + themes | Spectrum/light/dark, accent, font and size. Live preview with Apply/Revert. Persists across restart. Restore defaults. Invalid colour rejected. |
| M10 | Admin companion | CRUD/reorder/enable categories and options, fragment editor, conditions, template editor, live preview with sample data, validate, export/import, restore defaults, warnings on system-element removal, lock handling. Main app keeps working with Admin closed. |
| M11 | AppBar provider scaffold + simulated UIA harness | Simulated missing control, stale value, layout change and transient failure → correct statuses, no crash, no change to workflows or notes. Your structure-changed event plugs into `OnNewCall`. |
| M12 | Docs + test results + packaging | SETUP, ARCHITECTURE, TESTPLAN with actual results, CHECKLIST, known limitations. Optional Ahk2Exe build. |

Full test plan (brief §11, items 1–13) will be kept in `docs/TESTPLAN.md`, with expected vs. actual results and how each was run (automated / mock GUI / requires real AppBar).
