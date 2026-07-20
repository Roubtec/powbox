#!/usr/bin/env node
// Focused unit test for wf-address-tasks.js's `mainCheckoutSummary` — the
// non-destructive shared-main-checkout cleanliness report. The workflow is a
// runtime script (top-level await/return, injected `agent`/`phase`/`log`
// globals), so it cannot be imported as a module; instead we extract the pure
// `mainCheckoutSummary` function by source and evaluate it in isolation. This
// keeps the test honest — it exercises the ACTUAL shipped function, not a copy.
//
// Run: node scripts/test-checkout-cleanliness-report.mjs

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const workflowPath = join(here, "..", "docker", "claude", "agent-container", "workflows", "wf-address-tasks.js");
const src = readFileSync(workflowPath, "utf8");

// Extract `function mainCheckoutSummary(baseline, final) { ... }` up to the
// first closing brace at column 0 (the function's own — every inner `}` is
// indented). Fail loudly if the shape changed, so the test can't silently pass
// against a function it no longer found.
const match = src.match(/function mainCheckoutSummary\(baseline, final\) \{[\s\S]*?\n\}/);
if (!match) {
  console.error("FAIL: could not locate mainCheckoutSummary in the workflow source.");
  process.exit(1);
}
// eslint-disable-next-line no-new-func
const mainCheckoutSummary = new Function(`return (${match[0]});`)();

let failures = 0;
function check(name, cond, detail) {
  if (cond) {
    console.log(`ok  - ${name}`);
  } else {
    failures++;
    console.error(`NOT ok - ${name}${detail ? `: ${detail}` : ""}`);
  }
}

// The observation-only assurance every note must carry (kept in sync with the
// `OBSERVED` clause in the workflow). Its presence in a note is the machine-
// checkable proof that the note never reads as the report having mutated the
// tree — a far more robust invariant than a blunt "no mutation verb appears"
// blocklist, which would false-positive on the legitimate vanished-path note
// that names reset/clean/stash as hypothetical EXTERNAL causes.
const OBSERVED_RE = /only observed the checkout and changed nothing/i;
// A phrase that would WRONGLY assert the report/workflow itself mutated the
// tree. The vanished note says work "can mean … was committed, reset, cleaned,
// or stashed away" (hypothetical, external) — which must NOT match this.
const SELF_MUTATION_RE = /\b(?:this report|the report|the workflow|we|it)\s+(?:reset|cleaned|stashed|deleted|removed|discarded|modified|changed)\b/i;

// 1. Clean baseline, clean end → clean, not flagged, nothing new/gone.
{
  const r = mainCheckoutSummary({ measured: true, dirty: [] }, { measured: true, dirty: [] });
  check("clean start + clean end → not flagged", r.flagged === false && r.measured === true);
  check("clean end → no new/pre-existing/disappeared paths", r.newPaths.length === 0 && r.preexisting.length === 0 && r.disappeared.length === 0);
}

// 2. Dirty baseline unchanged → pre-existing only, NOT flagged, nothing attributed to the batch.
{
  const r = mainCheckoutSummary(
    { measured: true, dirty: ["?? src/a.ts", " M README.md"] },
    { measured: true, dirty: ["?? src/a.ts", " M README.md"] }
  );
  check("pre-existing dirt unchanged → not flagged", r.flagged === false);
  check("pre-existing dirt unchanged → no new paths", r.newPaths.length === 0);
  check("pre-existing dirt unchanged → nothing disappeared", r.disappeared.length === 0);
  check("pre-existing dirt counted as pre-existing", r.preexisting.length === 2);
  check("note does not claim batch created the dirt", !/created|agent-created|this batch (?:created|added)/i.test(r.note));
}

// 3. A new path appears during the batch → flagged, distinguished from pre-existing,
//    and NOT attributed solely to agents.
{
  const r = mainCheckoutSummary(
    { measured: true, dirty: [" M src/a.ts"] },
    { measured: true, dirty: [" M src/a.ts", "?? stray.txt"] }
  );
  check("new path during batch → flagged", r.flagged === true);
  check("new path isolated from pre-existing", r.newPaths.length === 1 && r.newPaths[0] === "?? stray.txt");
  check("pre-existing still tracked", r.preexisting.length === 1 && r.preexisting[0] === " M src/a.ts");
  check("new path → nothing disappeared", r.disappeared.length === 0);
  check("new-path note does not assert agent authorship", /no one in particular|could each be the source/i.test(r.note));
}

// 3b. FINDING 3: a path whose only change is its XY status code is the SAME
//     pre-existing path (a transition), NOT a brand-new one.
{
  const r = mainCheckoutSummary(
    { measured: true, dirty: [" M src/a.ts"] },
    { measured: true, dirty: ["MM src/a.ts"] }
  );
  check("status-code change → not a new path", r.newPaths.length === 0);
  check("status-code change → still counted pre-existing", r.preexisting.length === 1);
  check("status-code change → nothing disappeared", r.disappeared.length === 0);
  check("status-code change → recorded as a transition", r.transitions.length === 1 && r.transitions[0].path === "src/a.ts" && r.transitions[0].from === " M" && r.transitions[0].to === "MM");
  check("pure status transition → not flagged", r.flagged === false);
}

// 3c. FINDING 3: rename records (`XY orig -> new`) compare on the CURRENT path.
{
  const r = mainCheckoutSummary(
    { measured: true, dirty: ["R  old.ts -> new.ts"] },
    { measured: true, dirty: ["R  old.ts -> new.ts"] }
  );
  check("rename record → same current path, not new", r.newPaths.length === 0 && r.disappeared.length === 0 && r.preexisting.length === 1);
}

// 4. FINDING 1: a baseline-dirty path that DISAPPEARS by Summary must be
//    reported, never swallowed into a "clean" verdict.
{
  const r = mainCheckoutSummary(
    { measured: true, dirty: [" M src/a.ts", "?? notes.txt"] },
    { measured: true, dirty: [" M src/a.ts"] }
  );
  check("vanished baseline path → flagged", r.flagged === true);
  check("vanished baseline path → listed in disappeared", r.disappeared.length === 1 && r.disappeared[0] === "?? notes.txt");
  check("vanished baseline path → surviving path still pre-existing", r.preexisting.length === 1 && r.preexisting[0] === " M src/a.ts");
  check("vanished baseline path → no false new path", r.newPaths.length === 0);
  check("vanished note flags possible destructive loss", /lost|vanish|disappear/i.test(r.note));
}

// 4b. FINDING 1 (worst case): ALL baseline dirt vanishes and the end looks
//     clean → MUST still flag, and MUST NOT declare the checkout "clean".
{
  const r = mainCheckoutSummary(
    { measured: true, dirty: [" M src/a.ts", "?? notes.txt"] },
    { measured: true, dirty: [] }
  );
  check("all baseline dirt gone → flagged (not swallowed)", r.flagged === true);
  check("all baseline dirt gone → all reported disappeared", r.disappeared.length === 2);
  check("all baseline dirt gone → note does NOT declare clean", !/\bis clean\b/i.test(r.note));
}

// 5. No measured baseline but dirt at end → flagged, but explicitly NOT attributed to the batch.
{
  const r = mainCheckoutSummary(
    { measured: false, dirty: [] },
    { measured: true, dirty: ["?? x.txt"] }
  );
  check("no baseline + end dirt → flagged", r.flagged === true);
  check("no baseline → baselineKnown false", r.baselineKnown === false);
  check("no baseline → note declines attribution", /NOT attributed|not attributed/i.test(r.note));
}

// 6. No measured baseline + clean end → not flagged (nothing to report).
{
  const r = mainCheckoutSummary(null, { measured: true, dirty: [] });
  check("no baseline + clean end → not flagged", r.flagged === false);
}

// 7. Post-batch snapshot unmeasurable → measured false, never flagged, never fails.
{
  const r = mainCheckoutSummary({ measured: true, dirty: [" M src/a.ts"] }, { measured: false, dirty: [] });
  check("unmeasured end → measured false", r.measured === false);
  check("unmeasured end → not flagged", r.flagged === false);
  check("unmeasured end → note is observation-only", OBSERVED_RE.test(r.note));
}

// 8. FINDING 2: no note may claim the WHOLE workflow was non-destructive —
//    only the observation step is guaranteed so. Any note that touches
//    attribution of dirt (new/disappeared/unattributed) must name the caveat
//    that other stages ran in worktrees and are not separately proven clean.
{
  const attributingCases = [
    // new + disappeared paths
    [{ measured: true, dirty: [" M a"] }, { measured: true, dirty: [" M a", "?? b"] }],
    [{ measured: true, dirty: [" M a", "?? b"] }, { measured: true, dirty: [" M a"] }],
    // unmeasurable baseline, dirt at end
    [{ measured: false, dirty: [] }, { measured: true, dirty: ["?? b"] }],
    // unmeasurable end
    [{ measured: true, dirty: [" M a"] }, { measured: false, dirty: [] }],
  ];
  const allCaveat = attributingCases.every(([b, f]) => /not separately proven|per-task worktrees/i.test(mainCheckoutSummary(b, f).note));
  check("attributing notes never claim the whole workflow was non-destructive", allCaveat);
  const noWholeWorkflowClaim = attributingCases.every(([b, f]) => !/the workflow modified nothing|the workflow (?:made no|left).*(?:untouched|no changes)/i.test(mainCheckoutSummary(b, f).note));
  check("no note asserts 'the workflow modified nothing'", noWholeWorkflowClaim);
}

// 9. Observation-only contract: EVERY branch's note both carries the
//    observation-only assurance and never asserts the report/workflow itself
//    mutated the tree.
{
  const cases = [
    [{ measured: true, dirty: [] }, { measured: true, dirty: [] }],
    [{ measured: true, dirty: [" M a"] }, { measured: true, dirty: [" M a", "?? b"] }],
    [{ measured: true, dirty: [" M a", "?? b"] }, { measured: true, dirty: [] }], // all vanished
    [{ measured: true, dirty: [" M a", "?? b"] }, { measured: true, dirty: [" M a"] }], // one vanished
    [{ measured: true, dirty: [" M a"] }, { measured: true, dirty: ["MM a"] }], // transition
    [{ measured: false, dirty: [] }, { measured: true, dirty: ["?? b"] }],
    [{ measured: true, dirty: [" M a"] }, { measured: false, dirty: [] }],
    [null, { measured: false, dirty: [] }],
  ];
  const allObserved = cases.every(([b, f]) => OBSERVED_RE.test(mainCheckoutSummary(b, f).note));
  check("every note carries the observation-only assurance", allObserved);
  const selfMutation = cases.some(([b, f]) => SELF_MUTATION_RE.test(mainCheckoutSummary(b, f).note));
  check("no note asserts the report/workflow itself mutated the tree", !selfMutation);
}

if (failures) {
  console.error(`\n${failures} check(s) failed.`);
  process.exit(1);
}
console.log("\nAll checkout-cleanliness-report checks passed.");
