import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { buildADT } = require('./boot.js');
const adt = buildADT(0x235200000n);
function parse(buf, off, depth) {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const nProps = dv.getUint32(off, true), nKids = dv.getUint32(off + 4, true);
  let p = off + 8;
  let name = '?';
  for (let i = 0; i < nProps; i++) {
    let pn = '';
    for (let j = 0; j < 32; j++) { const c = buf[p + j]; if (!c) break; pn += String.fromCharCode(c); }
    const len = dv.getUint32(p + 32, true);
    const val = buf.subarray(p + 36, p + 36 + len);
    if (pn === 'name') name = val.toString('latin1').replace(/\0.*$/s, '');
    console.log(' '.repeat(depth * 2) + 'prop ' + pn + ' len ' + len + (len <= 16 ? ' = ' + Buffer.from(val).toString('hex') : ''));
    p += 36 + len + ((4 - (len % 4)) % 4);
  }
  console.log(' '.repeat(depth * 2) + 'node "' + name + '" props=' + nProps + ' children=' + nKids);
  for (let k = 0; k < nKids; k++) p = parse(buf, p, depth + 1);
  return p;
}
const end = parse(adt, 0, 0);
console.log('ADT total bytes:', adt.length, '| parsed end:', end, '| consistent:', end === adt.length);
