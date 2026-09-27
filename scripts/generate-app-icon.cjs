// Node.js와 sharp가 필요합니다. 타이틀바 SVG에서 Windows용 다중 해상도 ICO를 생성합니다.
// 실행: node scripts/generate-app-icon.cjs
const fs = require('node:fs');
const path = require('node:path');
const sharp = require('sharp');

async function main() {
  const assets = path.resolve(__dirname, '../src/PzTools.App/Assets/Navigation');
  const source = fs.readFileSync(path.join(assets, 'pztools.svg'));
  const sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256];
  const frames = await Promise.all(sizes.map(size =>
    sharp(source, { density: 72 * size / 24 }).resize(size, size).png().toBuffer()));

  const directory = Buffer.alloc(6 + sizes.length * 16);
  directory.writeUInt16LE(1, 2); // ICO
  directory.writeUInt16LE(sizes.length, 4);
  let offset = directory.length;
  frames.forEach((frame, index) => {
    const entry = 6 + index * 16;
    directory[entry] = sizes[index] === 256 ? 0 : sizes[index];
    directory[entry + 1] = directory[entry];
    directory.writeUInt16LE(1, entry + 4);
    directory.writeUInt16LE(32, entry + 6);
    directory.writeUInt32LE(frame.length, entry + 8);
    directory.writeUInt32LE(offset, entry + 12);
    offset += frame.length;
  });
  const output = path.join(assets, 'pztools.ico');
  fs.writeFileSync(output, Buffer.concat([directory, ...frames]));
  console.log(`아이콘 생성: ${output} (${sizes.join(', ')}px)`);
}

main().catch(error => { console.error(error); process.exitCode = 1; });
