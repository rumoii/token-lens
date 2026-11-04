import { appendFileSync, existsSync, mkdirSync, renameSync, statSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';

// 同步落盘，启动失败立即 exit 时也保留 stderr；两条流共用一个轮转顺序。
export function enableDesktopLogs(dataDir) {
  const directory = join(dataDir, 'logs');
  mkdirSync(directory, { recursive: true });
  const file = join(directory, 'kernel.log');
  const limit = 5 * 1024 * 1024;
  let size = existsSync(file) ? statSync(file).size : 0;
  const write = chunk => {
    let offset = 0;
    while (offset < chunk.length) {
      if (size >= limit) {
        if (existsSync(`${file}.2`)) unlinkSync(`${file}.2`);
        if (existsSync(`${file}.1`)) renameSync(`${file}.1`, `${file}.2`);
        if (existsSync(file)) renameSync(file, `${file}.1`);
        size = 0;
      }
      const end = Math.min(chunk.length, offset + limit - size);
      appendFileSync(file, chunk.subarray(offset, end));
      size += end - offset;
      offset = end;
    }
  };
  for (const stream of [process.stdout, process.stderr]) {
    const original = stream.write.bind(stream);
    stream.write = (chunk, encoding, callback) => {
      write(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, typeof encoding === 'string' ? encoding : 'utf8'));
      return original(chunk, encoding, callback);
    };
  }
}
