#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const projectRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const checker = join(projectRoot, "scripts/check-websocket-verdicts.mjs");

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), "flyology-websocket-verdicts-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

async function writeCase(directory, id, behavior = "OK", behaviorClose = "OK") {
  const name = `flyology_case_${id.replaceAll(".", "_")}.json`;
  await writeFile(
    join(directory, name),
    `${JSON.stringify({ behavior, behaviorClose })}\n`
  );
}

async function writeCompressionCampaign(directory) {
  await writeCase(directory, "12.1.1");
  for (const subcategory of [3, 5]) {
    for (let caseNumber = 1; caseNumber <= 18; caseNumber += 1) {
      await writeCase(
        directory,
        `13.${subcategory}.${caseNumber}`,
        "UNIMPLEMENTED"
      );
    }
  }
}

function check(directory, profile = "compression") {
  return spawnSync(process.execPath, [checker, directory, profile, "native"], {
    cwd: projectRoot,
    encoding: "utf8",
  });
}

test("accepts only the documented 9-bit compression refusals", async (t) => {
  const directory = await fixture(t);
  await writeCompressionCampaign(directory);

  const result = check(directory);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /36 UNIMPLEMENTED/);
});

test("rejects a missing documented refusal", async (t) => {
  const directory = await fixture(t);
  await writeCompressionCampaign(directory);
  await writeCase(directory, "13.3.1", "OK");

  const result = check(directory);
  assert.equal(result.status, 1);
  assert.match(
    result.stderr,
    /missing expected documented compression refusal case_13_3_1\.json/
  );
});

test("rejects an additional unimplemented compression case", async (t) => {
  const directory = await fixture(t);
  await writeCompressionCampaign(directory);
  await writeCase(directory, "13.4.1", "UNIMPLEMENTED");

  const result = check(directory);
  assert.equal(result.status, 1);
  assert.match(
    result.stderr,
    /flyology_case_13_4_1\.json: unexpected behavior verdict UNIMPLEMENTED/
  );
});

test("rejects unimplemented behavior outside compression profiles", async (t) => {
  const directory = await fixture(t);
  await writeCase(directory, "1.1.1", "UNIMPLEMENTED");

  const result = check(directory, "core");
  assert.equal(result.status, 1);
  assert.match(result.stderr, /unexpected behavior verdict UNIMPLEMENTED/);
});

test("rejects a failed close for an expected compression refusal", async (t) => {
  const directory = await fixture(t);
  await writeCompressionCampaign(directory);
  await writeCase(directory, "13.5.18", "UNIMPLEMENTED", "FAILED");

  const result = check(directory);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /unexpected behaviorClose verdict FAILED/);
});
