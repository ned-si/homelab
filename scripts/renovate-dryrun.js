#!/usr/bin/env node
/*
 * Apply this repo's Renovate customManagers regexes to the tree and print what
 * they would detect.
 *
 * This is NOT a substitute for Renovate itself, but it answers the question that
 * actually matters when hand-writing regex managers: does each `# renovate:`
 * comment in the repo produce a dependency, and does every pinned version have a
 * comment?
 *
 * Usage: node scripts/renovate-dryrun.js
 * Exits 1 if any `# renovate:` annotation fails to yield a match, or if a
 * data-store image is not held by the data-store majors rule.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const root = path.resolve(__dirname, '..');
const cfgText = fs.readFileSync(path.join(root, '.github/renovate.json5'), 'utf8');
// JSON5 is valid JS object-literal syntax.
const cfg = new Function('return (' + cfgText + ')')();

// `-c` cached + `-o` others + `--exclude-standard` = tracked AND untracked but
// not git-ignored. Plain `git ls-files` would miss brand-new files, which is
// exactly when a broken annotation is introduced.
const files = execSync('git ls-files -co --exclude-standard', {
  cwd: root,
  encoding: 'utf8',
})
  .split('\n')
  .filter(Boolean);

function globToRe(p) {
  // managerFilePatterns entries look like "/\\.ya?ml$/"
  const m = /^\/(.*)\/$/.exec(p);
  return m ? new RegExp(m[1]) : new RegExp(p.replace(/\*/g, '.*'));
}

// Record the LINE each match started on, so an annotation can be tied to its
// detection rather than only to its file.
const found = [];
for (const mgr of cfg.customManagers) {
  const pats = mgr.managerFilePatterns.map(globToRe);
  for (const f of files) {
    if (!pats.some((re) => re.test(f))) continue;
    const abs = path.join(root, f);
    if (!fs.existsSync(abs) || fs.statSync(abs).isDirectory()) continue;
    const text = fs.readFileSync(abs, 'utf8');
    for (const ms of mgr.matchStrings) {
      const re = new RegExp(ms, 'gm');
      let m;
      while ((m = re.exec(text)) !== null) {
        const g = m.groups || {};
        // 1-indexed line of the `# renovate:` comment that matched.
        const line = text.slice(0, m.index).split('\n').length;
        found.push({
          file: f,
          line,
          datasource: g.datasource || mgr.datasourceTemplate,
          // Templates fill what the regex does not capture, as in Renovate.
          depName: g.depName || mgr.depNameTemplate || '(none)',
          currentValue: g.currentValue || mgr.currentValueTemplate,
        });
      }
    }
  }
}

// Every `# renovate:` annotation in the repo should have produced a match.
const annotations = [];
for (const f of files) {
  if (!/\.(ya?ml|tf|sh)$|Makefile$/.test(f)) continue;
  const abs = path.join(root, f);
  if (!fs.existsSync(abs) || fs.statSync(abs).isDirectory()) continue;
  const lines = fs.readFileSync(abs, 'utf8').split('\n');
  lines.forEach((l, i) => {
    if (/#\s*renovate:\s*datasource=/.test(l)) annotations.push(`${f}:${i + 1}`);
  });
}

// Match annotations to detections by exact file:line, not merely by file. A
// per-file check hides the case where a file has two annotations and only one
// of them works -- which is how three broken annotations went unnoticed once.
const matchedLocations = new Set(found.map((d) => `${d.file}:${d.line}`));
const unmatched = annotations.filter((a) => !matchedLocations.has(a));

const seen = new Set();
const uniq = found.filter((d) => {
  const k = `${d.file}:${d.line}`;
  if (seen.has(k)) return false;
  seen.add(k);
  return true;
});

console.log(
  `Detected ${uniq.length} dependencies from ${annotations.length} annotations\n`
);
for (const d of uniq.sort(
  (a, b) => a.file.localeCompare(b.file) || a.line - b.line
)) {
  const bad = d.depName === '(none)' || !d.currentValue ? '  <-- SUSPECT' : '';
  console.log(
    `  ${d.datasource.padEnd(18)} ${String(d.depName).padEnd(46)} ${String(
      d.currentValue
    ).padEnd(28)}${bad}`
  );
}

let rc = 0;
if (unmatched.length) {
  console.log('\nANNOTATIONS THAT PRODUCED NO MATCH:');
  unmatched.forEach((a) => console.log('  ' + a));
  rc = 1;
}
// A detection with no depName or no version is worse than no detection: it looks
// green and tracks nothing.
const suspect = uniq.filter((d) => d.depName === '(none)' || !d.currentValue);
if (suspect.length) {
  console.log('\nDETECTIONS MISSING depName OR version:');
  suspect.forEach((d) => console.log(`  ${d.file}:${d.line}`));
  rc = 1;
}
if (rc === 0) {
  console.log('\nevery `# renovate:` annotation produced a complete match');
}

// Every data-store image the cluster runs must stay under the "No automerge
// for data-store majors" rule: a major rewrites the on-disk format and a revert
// cannot undo it (#559). The names are the ones Renovate reports as depName; a
// name that no longer appears in the tree fails too, so the list cannot rot.
const DATA_STORE_IMAGES = [
  'ghcr.io/cloudnative-pg/postgresql',
  'ghcr.io/tensorchord/cloudnative-vectorchord',
  'docker.io/clickhouse/clickhouse-server',
  'docker.io/signoz/zookeeper',
  'valkey/valkey',
];
const storeRule = (cfg.packageRules || []).find(
  (r) => r.description === 'No automerge for data-store majors'
);
const storeProblems = [];
if (
  !storeRule ||
  storeRule.automerge !== false ||
  JSON.stringify(storeRule.matchUpdateTypes) !== '["major"]'
) {
  storeProblems.push('rule "No automerge for data-store majors" missing or changed');
} else {
  const res = storeRule.matchPackageNames.map((p) => globToRe(p));
  const tree = files
    .filter((f) => /\.ya?ml$/.test(f) && fs.existsSync(path.join(root, f)))
    .map((f) => fs.readFileSync(path.join(root, f), 'utf8'))
    .join('\n');
  for (const img of DATA_STORE_IMAGES) {
    if (!res.some((re) => re.test(img))) storeProblems.push(`${img}: not matched by the rule`);
    // Chart values carry the image without the docker.io/ prefix.
    if (!tree.includes(img.replace(/^docker\.io\//, ''))) {
      storeProblems.push(`${img}: not in the tree any more, drop it from DATA_STORE_IMAGES`);
    }
  }
}
if (storeProblems.length) {
  console.log('\nDATA-STORE MAJORS:');
  storeProblems.forEach((p) => console.log('  ' + p));
  rc = 1;
} else {
  console.log(`every data-store image (${DATA_STORE_IMAGES.length}) holds its majors`);
}
process.exit(rc);
