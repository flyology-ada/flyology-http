#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

const [reportDir, profile, lane] = process.argv.slice(2);
if (!reportDir || !profile || !lane) {
  console.error("usage: check-websocket-verdicts.mjs REPORT_DIR PROFILE LANE");
  process.exit(2);
}

const allowed = new Set(["OK", "NON-STRICT", "INFORMATIONAL"]);
const fields = ["behavior", "behaviorClose"];
const counts = Object.fromEntries(fields.map((field) => [field, new Map()]));
const expectedUnimplemented = new Set();
let failed = false;

if (profile === "compression" || profile === "compression-wss") {
  //  Autobahn 13.3.* and 13.5.* require server_max_window_bits=9. The public
  //  server contract deliberately declines values below 15 because outbound
  //  compression uses a 32 KiB history. Keep the cases in the campaign and
  //  require their exact refusal instead of broadly allowing UNIMPLEMENTED.
  for (const subcategory of [3, 5]) {
    for (let caseNumber = 1; caseNumber <= 18; caseNumber += 1) {
      expectedUnimplemented.add(`case_13_${subcategory}_${caseNumber}.json`);
    }
  }
}

let files;
try {
  files = fs.readdirSync(reportDir)
    .filter((name) => /_case_.*\.json$/.test(name))
    .sort();
} catch (error) {
  console.error(`cannot read Autobahn report directory ${reportDir}: ${error.message}`);
  process.exit(1);
}

if (files.length === 0) {
  console.error(`no Autobahn case reports found in ${reportDir}`);
  process.exit(1);
}

for (const name of files) {
  let report;
  try {
    report = JSON.parse(fs.readFileSync(path.join(reportDir, name), "utf8"));
  } catch (error) {
    console.error(`${name}: invalid JSON: ${error.message}`);
    failed = true;
    continue;
  }

  for (const field of fields) {
    const verdict = report[field];
    if (typeof verdict !== "string" || verdict.length === 0) {
      console.error(`${name}: missing or invalid ${field} verdict`);
      failed = true;
      continue;
    }
    counts[field].set(verdict, (counts[field].get(verdict) ?? 0) + 1);
    const expectedRefusal =
      field === "behavior" &&
      verdict === "UNIMPLEMENTED" &&
      [...expectedUnimplemented].find((suffix) => name.endsWith(suffix));
    if (expectedRefusal) {
      expectedUnimplemented.delete(expectedRefusal);
    } else if (!allowed.has(verdict)) {
      console.error(`${name}: unexpected ${field} verdict ${verdict}`);
      failed = true;
    }
  }
}

for (const suffix of [...expectedUnimplemented].sort()) {
  console.error(`missing expected documented compression refusal ${suffix}`);
  failed = true;
}

function printCounts(label, values) {
  console.log(`Autobahn ${label} verdicts (${profile}, ${lane}):`);
  for (const [verdict, count] of [...values].sort(([a], [b]) => a.localeCompare(b))) {
    console.log(`${String(count).padStart(7)} ${verdict}`);
  }
}

printCounts("behavior", counts.behavior);
printCounts("close", counts.behaviorClose);
if (failed) {
  process.exit(1);
}
