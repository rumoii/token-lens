/**
 * 把日志里的工作目录归一成项目键。
 *
 * 项目键就是用户看到的路径，不做缩写、不做哈希：
 * `D:\work\app` 与 `/home/alice/src/app` 各自成组，识别不了就是 `null`。
 */

/**
 * @param {unknown} value 日志里的 cwd 字段
 * @returns {string|null}
 */
export function projectFromCwd(value) {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  if (!trimmed) return null;

  // Windows 盘符路径统一分隔符并去掉尾部分隔符
  if (/^[A-Za-z]:[\\/]/.test(trimmed)) {
    return trimmed.replace(/\//g, '\\').replace(/\\+$/, '');
  }

  // POSIX 路径：去掉尾部斜杠，根目录保留
  const collapsed = trimmed.replace(/\/+$/, '');
  return collapsed || '/';
}

/**
 * 从若干候选里挑第一个能用的项目键。
 *
 * @param {...unknown} candidates
 * @returns {string|null}
 */
export function firstProject(...candidates) {
  for (const candidate of candidates) {
    const project = projectFromCwd(candidate);
    if (project) return project;
  }
  return null;
}
