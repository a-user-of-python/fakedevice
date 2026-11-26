import { readFileSync, writeFileSync } from 'fs';
const emu = readFileSync('./emu.js', 'utf8');
const boot = readFileSync('./boot.js', 'utf8');
let tpl = readFileSync('./page3_template.html', 'utf8');
if (emu.includes('</script') || boot.includes('</script')) throw new Error('script body contains </script');
tpl = tpl.replace('/*__EMU_JS__*/', () => emu).replace('/*__BOOT_JS__*/', () => boot);
writeFileSync('../../your_files/FakeDevice-XNU-stage3.html', tpl);
console.log('page written:', tpl.length, 'bytes');
