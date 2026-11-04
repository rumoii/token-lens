import { zstdDecompressSync } from 'node:zlib';

/**
 * Zstd 魔数（little-endian 0xFD2FB528）。
 */
const ZSTD_MAGIC = 0xfd2fb528;

/**
 * Skippable frame 魔数区间 [0x184D2A50, 0x184D2A5F]。
 */
const SKIPPABLE_MIN = 0x184d2a50;
const SKIPPABLE_MAX = 0x184d2a5f;

/**
 * 计算单个 zstd frame 的字节长度。
 *
 * node:zlib 的 zstd 解码器只解第一帧，遇到拼接的多帧输入会静默丢弃后续帧。
 * 客户端写出的 .jsonl.zst 可能由多帧拼接而成，因此必须先按 frame 边界切分，
 * 再逐帧解码，否则尾部记录会被悄悄丢掉。
 *
 * 帧结构（RFC 8878 §3.1）：
 *   magic(4) | Frame_Header_Descriptor(1) | [Window_Descriptor] | [Dictionary_ID] |
 *   [Frame_Content_Size] | blocks... | [Content_Checksum(4)]
 * 每个 block 头部 3 字节：last_block(1bit) | block_type(2bit) | block_size(21bit)。
 *
 * @param {Buffer} buf
 * @param {number} start 帧起点
 * @returns {number} 帧结束后的偏移
 * @throws {Error} 结构非法时抛出，交由调用方决定是否放弃整份文件
 */
function frameEnd(buf, start) {
  if (start + 5 > buf.length) {
    throw new Error('zstd frame truncated before header');
  }

  const magic = buf.readUInt32LE(start);
  if (magic >= SKIPPABLE_MIN && magic <= SKIPPABLE_MAX) {
    if (start + 8 > buf.length) {
      throw new Error('zstd skippable frame truncated');
    }
    const size = buf.readUInt32LE(start + 4);
    const end = start + 8 + size;
    if (end > buf.length) {
      throw new Error('zstd skippable frame exceeds buffer');
    }
    return end;
  }

  if (magic !== ZSTD_MAGIC) {
    throw new Error(`zstd magic mismatch at ${start}`);
  }

  let pos = start + 5;
  const fhd = buf[start + 4];
  const fcsFlag = fhd >> 6;
  const singleSegment = (fhd >> 5) & 1;
  const checksumFlag = (fhd >> 2) & 1;
  const dictIdFlag = fhd & 3;

  if (!singleSegment) {
    pos += 1; // Window_Descriptor
  }

  pos += [0, 1, 2, 4][dictIdFlag];

  const fcsSize = [singleSegment ? 1 : 0, 2, 4, 8][fcsFlag];
  pos += fcsSize;

  if (pos > buf.length) {
    throw new Error('zstd frame header exceeds buffer');
  }

  for (;;) {
    if (pos + 3 > buf.length) {
      throw new Error('zstd block header truncated');
    }
    const header = buf[pos] | (buf[pos + 1] << 8) | (buf[pos + 2] << 16);
    const lastBlock = header & 1;
    const blockType = (header >> 1) & 3;
    const blockSize = header >> 3;
    pos += 3;

    if (blockType === 0 || blockType === 2) {
      pos += blockSize;
    } else if (blockType === 1) {
      pos += 1; // RLE block：1 字节填充值
    } else {
      throw new Error('zstd reserved block type');
    }

    if (pos > buf.length) {
      throw new Error('zstd block exceeds buffer');
    }

    if (lastBlock) break;
  }

  if (checksumFlag) pos += 4;
  if (pos > buf.length) {
    throw new Error('zstd checksum truncated');
  }

  return pos;
}

/**
 * 解码可能由多帧拼接而成的 zstd 数据。
 *
 * @param {Buffer|Uint8Array} input
 * @returns {Buffer} 所有帧解压后按顺序拼接的内容
 * @throws {Error} 输入不是合法 zstd 数据时抛出
 */
export function decompressZstdFrames(input) {
  const buf = Buffer.isBuffer(input) ? input : Buffer.from(input);

  if (buf.length === 0) {
    return Buffer.alloc(0);
  }

  const parts = [];
  let offset = 0;

  while (offset < buf.length) {
    const end = frameEnd(buf, offset);
    const magic = buf.readUInt32LE(offset);
    if (magic === ZSTD_MAGIC) {
      parts.push(zstdDecompressSync(buf.subarray(offset, end)));
    }
    // skippable frame 只跳过，不产出内容
    offset = end;
  }

  return Buffer.concat(parts);
}

/**
 * 供 .jsonl.zst 适配器使用：解码为 utf8 文本。
 *
 * @param {Buffer|Uint8Array} input
 * @returns {string}
 */
export function decompressZstdText(input) {
  return decompressZstdFrames(input).toString('utf8');
}
