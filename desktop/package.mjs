// 打包与体积检查共用此入口，超限时不产生可分发文件。
export function assembleExe(shell, compressed, manifest) {
  const json = Buffer.from(JSON.stringify(manifest));
  const footer = Buffer.alloc(12);
  footer.writeUInt32LE(json.length);
  footer.write('TLENS001', 4);
  const size = shell.length + compressed.length + json.length + footer.length;
  if (size > 30_000_000) throw new Error(`Desktop exe exceeds 30MB: ${size} bytes`);
  return Buffer.concat([shell, compressed, json, footer]);
}
