import { decode } from './src/codecs/avif.ts';

// QuickJS has no browser atob. ImageScript uses it for its built-in AV1 tables.
globalThis.atob ??= function (encoded) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let decoded = '';
  let bits = 0;
  let word = 0;
  for (const character of encoded) {
    if (character === '=') break;
    word = (word << 6) | alphabet.indexOf(character);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      decoded += String.fromCharCode((word >>> bits) & 255);
    }
  }
  return decoded;
};

globalThis.decodeAvifPage = async function (bytes, maxPixels) {
  if (!Number.isSafeInteger(maxPixels) || maxPixels <= 0) {
    throw new RangeError('Invalid AVIF pixel limit');
  }
  const { width, height, pixels } = await decode(new Uint8Array(bytes), maxPixels);
  const buffer = pixels.byteOffset === 0 && pixels.byteLength === pixels.buffer.byteLength
    ? pixels.buffer
    : pixels.slice().buffer;
  return { width, height, pixels: buffer };
};
