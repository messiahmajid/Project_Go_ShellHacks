// Fixed synthetic observations; this checks Gemini planning, not a live app.
import fs from 'node:fs';
const root = new URL('../', import.meta.url);
const values = Object.fromEntries(fs.readFileSync(new URL('worker/.dev.vars', root), 'utf8').split('\n')
  .filter(line => line.trim() && !line.trim().startsWith('#') && line.includes('='))
  .map(line => { const i = line.indexOf('='); return [line.slice(0, i).trim(), line.slice(i + 1).trim().replace(/^["']|["']$/g, '')]; }));
const endpoint = 'http://127.0.0.1:8787/go-plan';
const unauthorized = await fetch(endpoint, {method:'POST', body:'{}'});
console.log(JSON.stringify({check:'unauthenticated',status:unauthorized.status,passed:unauthorized.status === 401}));
let passed = unauthorized.status === 401;
for (const [index, label] of ['Round', 'Muted'].entries()) {
  if (process.argv[2] !== undefined && Number(process.argv[2]) !== index) continue;
  const id = `c${index + 7}`;
  const body = {
    goal: {id:'fixture',rawGoal:`Choose ${label}.`,lastInstruction:`Choose ${label}.`,task:'choose_option',status:'active'},
    observation: {app:`test.fixture.${index}`,windowToken:`window-${index}`,windowName:'Options',complete:true,
      controls:[{id,role:'AXRadioButton',name:label,radioSelection:false}],menus:[]},
    verifiedSteps: [], catalogLimited:false,
  };
  const start = performance.now();
  const response = await fetch(endpoint, {method:'POST',headers:{'Content-Type':'application/json','X-Go-Client-Key':values.GO_CLIENT_KEY},body:JSON.stringify(body)});
  const proposal = await response.json();
  const ok = response.ok && proposal.kind === 'step' && proposal.targetID === id && proposal.expected?.kind === 'radioSelected' && proposal.expected?.name === label;
  passed &&= ok;
  console.log(JSON.stringify({check:`fixture-${index}`,status:response.status,passed:ok,milliseconds:Math.round(performance.now()-start),proposal}));
}
process.exitCode = passed ? 0 : 1;
