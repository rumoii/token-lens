import { parseOpencodeDb } from './opencode.js';

/** MiMo Code 复用同构的 OpenCode 库解析，不产出旧的 timestamp 别名。 */
export async function* parseMimo(filePath, notes) {
  for await (const { timestamp, ...record } of parseOpencodeDb(filePath, notes, 'mimo')) {
    yield record;
  }
}
