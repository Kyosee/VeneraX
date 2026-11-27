// Regenerate the offline decoder with Bun 1.3.1 and the ImageScript checkout below.
// git clone --depth 1 --branch v4.0.1 https://github.com/imagescript/ImageScript.git
// bun tool/avif/build.mjs path/to/ImageScript
import { copyFile, cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const source = resolve(process.argv[2] ?? 'ImageScript');
const upstream = 'https://github.com/imagescript/ImageScript/tree/0a4df399603a83ac2098186173aac00308d21ec2';
const assets = fileURLToPath(new URL('../../assets/avif/', import.meta.url));
const entry = fileURLToPath(new URL('entry.js', import.meta.url));
const staging = await mkdtemp(join(tmpdir(), 'venerax-avif-'));
try {
  await mkdir(assets, { recursive: true });
  await cp(join(source, 'src'), join(staging, 'src'), { recursive: true });
  await copyFile(entry, join(staging, 'entry.js'));
  const result = Bun.spawnSync([
    process.execPath, 'build', 'entry.js', '--target=browser', '--format=iife',
    '--define', 'import.meta.url=""', // Worker URLs are unused in QuickJS.
    '--banner=// ImageScript v4.0.1 AVIF decoder. See LICENSE.txt and tool/avif/build.mjs.',
    `--outfile=${join(assets, 'decode.js')}`,
  ], { cwd: staging, stderr: 'inherit' });
  if (!result.success) throw new Error('Could not bundle the AVIF decoder');

  const license = await readFile(join(source, 'LICENSE'), 'utf8');
  const notices = await readFile(join(source, 'THIRD_PARTY_NOTICES.md'), 'utf8');
  const sections = notices.replaceAll('\r\n', '\n').split(/(?=^## )/m);
  const included = sections.filter(section => /^## (fflate, Fast CRC32 in JavaScript|dav1d|libavif)\n/.test(section));
  await writeFile(join(assets, 'LICENSE.txt'), [
    `ImageScript v4.0.1 AVIF decoder\n${upstream}`,
    license.replaceAll('\r\n', '\n').trim(),
    ...included.map(section => section.trim()),
  ].join('\n\n') + '\n');
} finally {
  await rm(staging, { recursive: true, force: true });
}
