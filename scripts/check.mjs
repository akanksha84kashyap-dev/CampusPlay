import { readdir } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
const files=['app.js',...(await readdir('netlify/functions')).filter(f=>f.endsWith('.mjs')).map(f=>`netlify/functions/${f}`)];
let failed=false;
for(const file of files){const result=spawnSync(process.execPath,['--check',file],{stdio:'inherit'});if(result.status!==0)failed=true}
if(failed)process.exit(1);console.log(`Syntax check passed for ${files.length} JavaScript files.`);
