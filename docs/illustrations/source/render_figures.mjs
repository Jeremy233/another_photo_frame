// SVG rasterization only. The generated landscape is used without pixel editing.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url);
const sharp = require(process.env.PHOTOFRAME_SHARP_MODULE || 'sharp');
const photo = await fs.readFile(path.join(root, 'source/landscape-sample.png'));
const data = `data:image/png;base64,${photo.toString('base64')}`;

for (const file of (await fs.readdir(root)).filter(f => /^\d{2}-.*\.svg$/.test(f)).sort()) {
  const source = (await fs.readFile(path.join(root, file), 'utf8'))
    .replaceAll('source/landscape-sample.png', data);
  const result = await sharp(Buffer.from(source), { density: 144 })
    .png({ compressionLevel: 9 })
    .toFile(path.join(root, file.replace(/\.svg$/, '.png')));
  console.log(`${file}: ${result.width} × ${result.height}, ${Math.round(result.size / 1024)} KiB`);
}
