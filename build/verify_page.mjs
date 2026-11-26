import { readFileSync } from 'fs';
const html = readFileSync('../../your_files/FakeDevice-XNU-stage2.html', 'utf8');
const script = html.split('<script>')[1].split('</script>')[0];

// minimal DOM stub
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

eval(script);

// 1) self-test
el('selftest').click();
await new Promise(r => setTimeout(r, 300));
console.log('SELFTEST uart:', JSON.stringify(el('uart').textContent));
console.log('SELFTEST status:', el('status').textContent.split('\n')[0]);

// 2) backdoor smoke on the halted self-test machine
el('bdin').value = 'regs'; el('bdrun').click();
el('bdin').value = 'peek 0x800000000 0x20'; el('bdrun').click();
el('bdin').value = 'patch 0x800000000 d503201f'; el('bdrun').click();
console.log('BACKDOOR out tail:', el('bdout').textContent.split('\n').slice(-8).join('\n'));

// 3) boot the real kernel through the page's own boot button
const raw = readFileSync('../kernelcache/kernelcache.raw');
const ab = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength);
el('kfile').files = [{ arrayBuffer: async () => ab }];
el('boot').click();
await new Promise(r => setTimeout(r, 1500));
console.log('BOOT status:', el('status').textContent);
console.log('BOOT log head:', el('log').textContent.split('\n').slice(0, 3).join(' | '));
