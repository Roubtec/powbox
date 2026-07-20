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

// 1. Clean baseline, clean end → clean, not flagged, nothing new.
{
  const r = mainCheckoutSummary({ measured: true, dirty: [] }, { measured: true, dirty: [] });
  check("clean start + clean end → not flagged", r.flagged === false && r.measured === true);
  check("clean end → no new paths", r.newPaths.length === 0 && r.preexisting.length === 0);
}

// 2. Dirty baseline unchanged → pre-existing only, NOT flagged, nothing attributed to the batch.
{
  const r = mainCheckoutSummary(
    { measured: true, dirty: ["src/a.ts", " M README.md"] },
    { measured: true, dirty: ["src/a.ts", " M README.md"] }
  );
  check("pre-existing dirt unchanged → not flagged", r.flagged === false);
  check("pre-existing dirt unchanged → no new paths", r.newPaths.length === 0);
  check("pre-existing dirt counted as pre-existing", r.preexisting.length === 2);
  check("note does not claim batch created the dirt", !/created|agent-created|this batch (?:created|added)/i.test(r.note));
}

// 3. A new path appears during the batch → flagged, distinguished from pre-existing,
//    and NOT attributed solely to agents.
{
  const r = mainCheckoutSummary(
    { measured: true, dirty: ["src/a.ts"] },
    { measured: true, dirty: ["src/a.ts", "?? stray.txt"] }
  );
  check("new path during batch → flagged", r.flagged === true);
  check("new path isolated from pre-existing", r.newPaths.length === 1 && r.newPaths[0] === "?? stray.txt");
  check("pre-existing still tracked", r.preexisting.length === 1 && r.preexisting[0] === "src/a.ts");
  check("new-path note does not assert agent authorship", /not attributed|could each be responsible|source not attributed/i.test(r.note));
}

// 4. No measured baseline but dirt at end → flagged, but explicitly NOT attributed to the batch.
{
  const r = mainCheckoutSummary(
    { measured: false, dirty: [] },
    { measured: true, dirty: ["?? x.txt"] }
  );
  check("no baseline + end dirt → flagged", r.flagged === true);
  check("no baseline → baselineKnown false", r.baselineKnown === false);
  check("no baseline → note declines attribution", /NOT attributed|not attributed/i.test(r.note));
}

// 5. No measured baseline + clean end → not flagged (nothing to report).
{
  const r = mainCheckoutSummary(null, { measured: true, dirty: [] });
  check("no baseline + clean end → not flagged", r.flagged === false);
}

// 6. Post-batch snapshot unmeasurable → measured false, never flagged, never fails.
{
  const r = mainCheckoutSummary({ measured: true, dirty: ["src/a.ts"] }, { measured: false, dirty: [] });
  check("unmeasured end → measured false", r.measured === false);
  check("unmeasured end → not flagged", r.flagged === false);
  check("unmeasured end → note says workflow modified nothing", /modified nothing/i.test(r.note));
}

// 7. Every branch of the return shape carries the observation-only contract:
//    no case should ever produce a note implying a mutation happened.
{
  const cases = [
    [{ measured: true, dirty: [] }, { measured: true, dirty: [] }],
    [{ measured: true, dirty: ["a"] }, { measured: true, dirty: ["a", "b"] }],
    [{ measured: false, dirty: [] }, { measured: true, dirty: ["a"] }],
    [null, { measured: false, dirty: [] }],
  ];
  const mutated = cases.some(([b, f]) => /\b(reset|cleaned|stashed|deleted|removed|discarded)\b/i.test(mainCheckoutSummary(b, f).note));
  check("no branch's note implies a mutation", !mutated);
}

if (failures) {
  console.error(`\n${failures} check(s) failed.`);
  process.exit(1);
}
console.log("\nAll checkout-cleanliness-report checks passed.");
