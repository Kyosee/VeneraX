const [version, ...assets] = process.argv.slice(2);
const match = /^(\d+\.\d+\.\d+)-([a-z\d-]+)(?:\.([a-z\d.-]+))?$/i.exec(version);
if (!match) throw new Error('Expected a prerelease version, e.g. 3.0.2-beta.2');

const [, number, channel, sequence] = match;
const lower = channel.toLowerCase();
const stage = lower === 'rc' ? 'RC' : lower[0].toUpperCase() + lower.slice(1);
const formats = [
  ['Android', /\.apk$/i],
  ['HarmonyOS', /\.hap$/i],
  ['iOS', /\.ipa$/i],
  ['Windows', /(?:\.exe|-windows\.zip)$/i],
  ['macOS', /\.dmg$/i],
  ['Linux', /(?:\.deb|\.AppImage|\.pkg\.tar\.zst)$/i],
];
const platforms = formats
  .filter(([, pattern]) => assets.some(asset => pattern.test(asset)))
  .map(([name]) => name);
const last = platforms.pop();
if (!last) throw new Error('No supported platform packages found');
const scope = platforms.length ? `${platforms.join(', ')} & ${last}` : last;
console.log(`v${[number, stage, sequence].filter(Boolean).join(' ')} (${scope})`);
