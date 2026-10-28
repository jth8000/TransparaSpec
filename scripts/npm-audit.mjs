#!/usr/bin/env node
// `npm audit` for production dependencies, with a reviewed allowlist.
//
// Plain `npm audit` would fail forever on advisories inside Expo's build
// tooling that only an Expo release can fix. So each advisory we've looked
// at and accepted is listed, with the reason, in npm-audit-allowlist.json.
// The check fails on any advisory not in the list, and on any list entry
// that npm no longer reports, so the list shrinks as fixes ship.

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const allowlist = JSON.parse(
  readFileSync(new URL('./npm-audit-allowlist.json', import.meta.url), 'utf8'),
);

function audit() {
  try {
    return execFileSync('npm', ['audit', '--omit=dev', '--json'], { encoding: 'utf8' });
  } catch (err) {
    // npm audit exits non-zero when it finds anything; the report is still on stdout.
    if (err.stdout) return err.stdout;
    throw err;
  }
}

const report = JSON.parse(audit());
if (report.error) {
  console.error('npm audit failed:', report.error.summary ?? report.error);
  process.exit(2);
}

// Each advisory appears as an object in `via` of the package it affects;
// string entries just point at another vulnerable package.
const found = new Map();
for (const vuln of Object.values(report.vulnerabilities ?? {})) {
  for (const via of vuln.via) {
    if (typeof via !== 'object') continue;
    const id = via.url.split('/').pop();
    found.set(id, { id, package: via.name, severity: via.severity, title: via.title, url: via.url });
  }
}

const allowed = new Map(allowlist.map((entry) => [entry.id, entry]));
const unreviewed = [...found.values()].filter((a) => !allowed.has(a.id));
const stale = allowlist.filter((entry) => !found.has(entry.id));

for (const a of found.values()) {
  if (allowed.has(a.id)) console.log(`accepted  ${a.severity.padEnd(8)} ${a.package}: ${a.id} (${a.title})`);
}
for (const a of unreviewed) {
  console.error(`NEW       ${a.severity.padEnd(8)} ${a.package}: ${a.title}\n          ${a.url}`);
}
for (const entry of stale) {
  console.error(`STALE     ${entry.package}: ${entry.id} is no longer reported; remove it from the allowlist`);
}

if (unreviewed.length > 0 || stale.length > 0) {
  console.error(
    '\nFix or upgrade the package, or, if it can\'t reach production, add it to ' +
      'scripts/npm-audit-allowlist.json with the reason.',
  );
  process.exit(1);
}
console.log(`npm audit: ${found.size} advisories, all reviewed.`);
