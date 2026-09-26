import test from 'node:test';
import assert from 'node:assert/strict';
import {handleGoPlan} from '../src/go-plan.ts';
const context={goal:{status:'active',rawGoal:'Select the round option'},observation:{app:'example.any-app',complete:true,controls:[{id:'c7',role:'AXRadioButton',name:'Round',radioSelection:false}]},verifiedSteps:[]};
const request=body=>new Request('http://local/go-plan',{method:'POST',body:typeof body==='string'?body:JSON.stringify(body)});
test('missing key, malformed context and oversized bodies never reach the provider', async()=>{
 const original=globalThis.fetch;let calls=0;globalThis.fetch=async()=>{calls++;throw Error('unexpected');};
 try{
  assert.equal((await handleGoPlan(request(context))).status,503);
  assert.equal((await handleGoPlan(request('{'),'test-key')).status,400);
  assert.equal((await handleGoPlan(request('x'.repeat(1100001)),'test-key')).status,413);
  assert.equal((await handleGoPlan(request({...context,extra:'x'.repeat(96001)}),'test-key')).status,413);
  assert.equal(calls,0);
 }finally{globalThis.fetch=original;}
});
test('planner receives the supplied goal and controls and returns a structured proposal', async()=>{
 const original=globalThis.fetch;
 const proposal={kind:'step',instruction:'Select Round.',targetID:'c7',expected:{kind:'radioSelected',role:'AXRadioButton',name:'Round'}};
 globalThis.fetch=async(url,options)=>{
  assert.ok(url.endsWith(':generateContent'));
  const sent=JSON.parse(options.body);
  assert.deepEqual(JSON.parse(sent.contents[0].parts[0].text),context);
  assert.ok(sent.systemInstruction.parts[0].text.includes('untrusted data'));
  assert.ok(sent.systemInstruction.parts[0].text.includes('not proof of visible text or icon appearance'));
  assert.ok(sent.systemInstruction.parts[0].text.includes('do not say "here"'));
  assert.equal(options.headers['x-goog-api-key'],'test-key');
  return Response.json({candidates:[{finishReason:'STOP',content:{parts:[{text:JSON.stringify(proposal)}]}}]});
 };
 try{const response=await handleGoPlan(request(context),'test-key');assert.equal(response.status,200);const {usage,...returned}=await response.json();assert.deepEqual(returned,proposal);assert.equal(typeof usage.providerMs,'number');}
 finally{globalThis.fetch=original;}
});
test('provider errors and incomplete results cannot become instructions', async()=>{
 const original=globalThis.fetch;
 try{
  globalThis.fetch=async()=>new Response('private provider detail',{status:429});
  const failed=await handleGoPlan(request(context),'test-key');
  assert.equal(failed.status,502);assert.equal((await failed.json()).error,'plannerProviderError');
  globalThis.fetch=async()=>Response.json({candidates:[{finishReason:'MAX_TOKENS',content:{parts:[{text:'{}'}]}}]});
  assert.equal((await (await handleGoPlan(request(context),'test-key')).json()).error,'plannerIncomplete');
 }finally{globalThis.fetch=original;}
});
test('visual fallback is a separate image part with bounded validated input', async()=>{
 const original=globalThis.fetch;let calls=0;
 const jpeg='/9j/2Q==';
 globalThis.fetch=async(url,options)=>{
  calls++;
  const sent=JSON.parse(options.body);
  assert.deepEqual(JSON.parse(sent.contents[0].parts[0].text),context);
  assert.deepEqual(sent.contents[0].parts[1],{inlineData:{mimeType:'image/jpeg',data:jpeg}});
  return Response.json({candidates:[{finishReason:'STOP',content:{parts:[{text:JSON.stringify({kind:'ask',instruction:'The dialog is open. What name do you want?'})}]}}]});
 };
 try{
  assert.equal((await handleGoPlan(request({...context,screenshotJPEG:jpeg}),'test-key')).status,200);
  for(const image of ['not an image','/9j/!!!!','/9j/'+ 'A'.repeat(1000000)]){
   assert.ok((await handleGoPlan(request({...context,screenshotJPEG:image}),'test-key')).status>=400);
  }
  assert.equal(calls,1);
 }finally{globalThis.fetch=original;}
});
test('a screen box without a screenshot comes back as a request to see the screen', async()=>{
 const original=globalThis.fetch;
 globalThis.fetch=async()=>Response.json({candidates:[{finishReason:'STOP',content:{parts:[{text:JSON.stringify({kind:'step',instruction:'Click the icon.',targetID:'screen',box:[0,900,30,930],label:'icon',needScreen:false})}]}}]});
 try{
  const blind=await (await handleGoPlan(request(context),'test-key')).json();
  assert.equal(blind.kind,'ask');assert.equal(blind.targetID,null);assert.equal(blind.box,null);assert.equal(blind.needScreen,true);
  const seen=await (await handleGoPlan(request({...context,screenshotJPEG:'/9j/2Q=='}),'test-key')).json();
  assert.equal(seen.targetID,'screen');assert.deepEqual(seen.box,[0,900,30,930]);
 }finally{globalThis.fetch=original;}
});
