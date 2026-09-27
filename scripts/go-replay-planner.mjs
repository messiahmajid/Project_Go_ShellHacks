// Re-asks the planner about real screens saved by Go's run recorder (see
// GoRunRecorder.swift) and reports where its answer changed: run after editing
// the planner prompt. Uses the local worker and a little API credit per case.
//
//   node scripts/go-replay-planner.mjs          # the newest 10 cases
//   node scripts/go-replay-planner.mjs 30       # the newest 30
//
// Prints kinds and targets only, never screen content.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const root = new URL('../', import.meta.url);
const values = Object.fromEntries(fs.readFileSync(new URL('worker/.dev.vars', root), 'utf8').split('\n')
  .filter(line => line.trim() && !line.trim().startsWith('#') && line.includes('='))
  .map(line => { const i = line.indexOf('='); return [line.slice(0, i).trim(), line.slice(i + 1).trim().replace(/^["']|["']$/g, '')]; }));
const folder = path.join(os.homedir(), 'Library/Application Support/Go/test-cases');
const limit = Number(process.argv[2] ?? 10);
const files = fs.existsSync(folder) ? fs.readdirSync(folder).filter(f => f.endsWith('.json')).sort().slice(-limit) : [];
if (files.length === 0) {
  console.log('No saved cases yet. Switch recording on, do a few runs, then try again.');
  process.exit(0);
}

const target = p => p.targetID === 'screen' ? 'screenBox' : (p.targetID ?? 'none');
let changed = 0;
for (const file of files) {
  const saved = JSON.parse(fs.readFileSync(path.join(folder, file), 'utf8'));
  const response = await fetch('http://127.0.0.1:8787/go-plan', {
    method: 'POST', headers: {'Content-Type': 'application/json', 'X-Go-Client-Key': values.GO_CLIENT_KEY},
    body: JSON.stringify(saved.context),
  });
  const now = await response.json();
  const before = `${saved.proposal.kind}:${target(saved.proposal)}`;
  const after = response.ok ? `${now.kind}:${target(now)}` : `error:${now.error ?? response.status}`;
  const same = before === after;
  if (!same) changed += 1;
  console.log(`${same ? '  same   ' : '  CHANGED'}  ${file}  ${saved.observation.app}  was ${before}  now ${after}  (${now.usage?.providerMs ?? '?'} ms)`);
}
console.log(`\n${files.length} cases, ${changed} changed. A change isn't always wrong: check the changed ones in the app.`);
