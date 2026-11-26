import { readFileSync } from 'fs';
const html = readFileSync('../../your_files/FakeDevice-XNU-stage4.html', 'utf8');
const scripts = html.split('<script>').slice(1).map(s => s.split('</script>')[0]);
console.log('script blocks:', scripts.length, '| sizes:', scripts.map(s => s.length).join(', '));
const els = {};
function el(id) {
  if (!els[id]) els[id] = {
    id, textContent: '', value: '', files: [], listeners: {}, scrollTop: 0, scrollHeight: 0,
    addEventListener(k, f) { this.listeners[k] = f; },
    click() { if (this.listeners.click) this.listeners.click(); },
    focus() {},
  };
  return els[id];
}
globalThis.document = { getElementById: el };
globalThis.window = globalThis;
const geval = eval;
for (const s of scripts) geval(s);   // indirect eval = browser-like global scope across script blocks

// 1) self-test
el('selftest').click();
await new Promise(r => setTimeout(r, 300));
console.log('SELFTEST uart:', JSON.stringify(el('uart').textContent));

// 2) boot the EMBEDDED kernel (no file picked)
el('boot').click();
for (let i = 0; i < 90; i++) {
  await new Promise(r => setTimeout(r, 1000));
  if (el('bdout').textContent.includes('parked') || el('status').textContent.includes('status: trap') || el('status').textContent.includes('status: halted')) break;
}
console.log('BOOT status:', el('status').textContent);
console.log('BOOT log:', el('log').textContent.split('\n').slice(0, 6).join('\n'));
const st = el('status').textContent, bd = el('bdout').textContent;
console.log('VERDICT:', st.includes('exceptions delivered: 1') && st.includes('0xfffffff0081ba410') && bd.includes('parked')
  ? 'PASS — embedded kernel booted through the chain, 1 exception delivered to the kernel handler, kernel parked in its hang loop'
  : 'CHECK — see status above');
