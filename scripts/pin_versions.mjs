import fs from 'node:fs';
const lock = fs.readFileSync('pubspec.lock', 'utf8');
const versions = {};
const re = /^  ([a-z0-9_]+):\n(?:.*\n)*?    version: "([^"]+)"/gm;
let m;
while ((m = re.exec(lock)) !== null) versions[m[1]] = m[2];
const files = [
  'packages/grua_core/pubspec.yaml',
  'apps/client_app/pubspec.yaml',
  'apps/driver_app/pubspec.yaml',
  'apps/admin_web/pubspec.yaml',
];
for (const f of files) {
  let src = fs.readFileSync(f, 'utf8');
  src = src.replace(/^(  )([a-z0-9_]+): any$/gm, (full, indent, name) => {
    const v = versions[name];
    if (!v) { console.warn('  ! no resolved version for', name, 'in', f); return full; }
    return `${indent}${name}: ^${v}`;
  });
  fs.writeFileSync(f, src);
  console.log('pinned', f);
}
