use lzma_rust2::LzmaReader;
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs::{self, File},
    io::{self, Read, Seek, SeekFrom, Write},
    path::{Component, Path, PathBuf},
};

const FOOTER: &[u8; 8] = b"TLENS001";
const ARCHIVE: &[u8; 8] = b"TLPL0001";
const MAX_UNPACKED: u64 = 512 * 1024 * 1024;

fn invalid(reason: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, reason)
}

fn hash_reader(mut reader: impl Read) -> io::Result<String> {
    let mut hash = Sha256::new();
    let mut buffer = [0; 65536];
    loop {
        let size = reader.read(&mut buffer)?;
        if size == 0 {
            break;
        }
        hash.update(&buffer[..size]);
    }
    Ok(format!("{:x}", hash.finalize()))
}

fn safe_path(name: &str) -> io::Result<PathBuf> {
    if name.is_empty()
        || name.contains(['\\', ':', '\0'])
        || name
            .split('/')
            .any(|part| part.is_empty() || part.ends_with(['.', ' ']))
    {
        return Err(invalid("载荷路径不合法"));
    }
    let path = PathBuf::from(name);
    if path
        .components()
        .any(|part| !matches!(part, Component::Normal(_)))
        || name.split('/').any(|part| {
            let stem = part.split('.').next().unwrap().to_ascii_uppercase();
            ["CON", "PRN", "AUX", "NUL"].contains(&stem.as_str())
                || (stem.len() == 4
                    && (stem.starts_with("COM") || stem.starts_with("LPT"))
                    && matches!(stem.as_bytes()[3], b'1'..=b'9'))
        })
    {
        return Err(invalid("载荷路径越界或包含保留名"));
    }
    Ok(path)
}

fn read_u32(reader: &mut impl Read) -> io::Result<u32> {
    let mut bytes = [0; 4];
    reader.read_exact(&mut bytes)?;
    Ok(u32::from_le_bytes(bytes))
}

// 格式仅包含普通文件；完成全部条目和 EOF 校验后，调用方才写完成标记。
fn unpack(mut reader: impl Read, root: &Path, expected_size: u64) -> io::Result<()> {
    let mut magic = [0; 8];
    reader.read_exact(&mut magic)?;
    if &magic != ARCHIVE {
        return Err(invalid("载荷版本不支持"));
    }
    let count = read_u32(&mut reader)?;
    if count == 0 || count > 10000 {
        return Err(invalid("载荷文件数不合法"));
    }
    let mut names = HashSet::new();
    let mut total = 12_u64;
    for _ in 0..count {
        let length = read_u32(&mut reader)? as usize;
        if length == 0 || length > 1024 {
            return Err(invalid("载荷路径过长"));
        }
        let mut size = [0; 8];
        reader.read_exact(&mut size)?;
        let size = u64::from_le_bytes(size);
        total = total
            .checked_add(12 + length as u64)
            .and_then(|n| n.checked_add(size))
            .ok_or_else(|| invalid("载荷大小溢出"))?;
        if total > MAX_UNPACKED || total > expected_size {
            return Err(invalid("载荷超过声明大小"));
        }
        let mut name = vec![0; length];
        reader.read_exact(&mut name)?;
        let name = std::str::from_utf8(&name).map_err(|_| invalid("载荷路径不是 UTF-8"))?;
        let relative = safe_path(name)?;
        if !names.insert(name.to_lowercase()) {
            return Err(invalid("载荷路径重复"));
        }
        let path = root.join(relative);
        fs::create_dir_all(path.parent().unwrap())?;
        let mut file = File::options().write(true).create_new(true).open(path)?;
        if io::copy(&mut reader.by_ref().take(size), &mut file)? != size {
            return Err(invalid("载荷文件截断"));
        }
        file.sync_all()?;
    }
    let mut extra = [0];
    if total != expected_size || reader.read(&mut extra)? != 0 {
        return Err(invalid("载荷长度不符"));
    }
    Ok(())
}

fn complete(root: &Path, hash: &str) -> bool {
    fs::read_to_string(root.join(".complete")).is_ok_and(|value| value == hash)
        && [
            "token-lens.exe",
            "node.exe",
            "bin/lens.js",
            "src/core/cli.js",
            "src/core/server.js",
            "src/core/package.json",
            "dashboard/dist/index.html",
            "package.json",
        ]
        .iter()
        .all(|file| root.join(file).is_file())
}

pub fn runtime_root() -> io::Result<PathBuf> {
    let exe = std::env::current_exe()?;
    let mut file = File::open(&exe)?;
    let size = file.metadata()?.len();
    if size < 12 {
        return Err(invalid("桌面 exe 不完整"));
    }
    file.seek(SeekFrom::End(-12))?;
    let manifest_size = read_u32(&mut file)? as u64;
    let mut magic = [0; 8];
    file.read_exact(&mut magic)?;
    if &magic != FOOTER {
        let root = exe.parent().unwrap();
        if let Ok(hash) = fs::read_to_string(root.join(".complete")) {
            if hash.len() == 64
                && hash.bytes().all(|b| b.is_ascii_hexdigit())
                && complete(root, &hash)
            {
                return Ok(root.to_owned());
            }
        }
        return Err(invalid(
            "未找到桌面载荷，请运行 desktop/dist 中构建的单 exe",
        ));
    }
    if manifest_size == 0 || manifest_size > 65536 || manifest_size + 12 > size {
        return Err(invalid("载荷元信息长度错误"));
    }
    file.seek(SeekFrom::Start(size - 12 - manifest_size))?;
    let mut bytes = vec![0; manifest_size as usize];
    file.read_exact(&mut bytes)?;
    let manifest: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|_| invalid("载荷元信息错误"))?;
    let version = manifest["version"]
        .as_str()
        .ok_or_else(|| invalid("载荷缺少版本"))?;
    if version.is_empty()
        || version.len() > 100
        || !version
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
    {
        return Err(invalid("载荷版本不合法"));
    }
    safe_path(version)?;
    let hash = manifest["sha256"]
        .as_str()
        .ok_or_else(|| invalid("载荷缺少 SHA-256"))?;
    if hash.len() != 64 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(invalid("载荷 SHA-256 格式错误"));
    }
    let compressed = manifest["compressed_size"]
        .as_u64()
        .ok_or_else(|| invalid("载荷缺少压缩大小"))?;
    let unpacked = manifest["unpacked_size"]
        .as_u64()
        .ok_or_else(|| invalid("载荷缺少原始大小"))?;
    if compressed == 0 || compressed > size - 12 - manifest_size || unpacked > MAX_UNPACKED {
        return Err(invalid("载荷大小错误"));
    }
    let offset = size - 12 - manifest_size - compressed;
    file.seek(SeekFrom::Start(offset))?;
    if hash_reader(Read::by_ref(&mut file).take(compressed))? != hash {
        return Err(invalid("载荷 SHA-256 校验失败"));
    }
    let base = PathBuf::from(
        std::env::var_os("LOCALAPPDATA").ok_or_else(|| invalid("LOCALAPPDATA 未设置"))?,
    )
    .join("token-lens-app");
    fs::create_dir_all(&base)?;
    let root = base.join(version);
    if complete(&root, hash) {
        return Ok(root);
    }
    if root.exists() {
        return Err(invalid(&format!(
            "解压目录不完整，请检查并移走后重试：{}",
            root.display()
        )));
    }
    let temporary = base.join(format!(
        ".{version}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(io::Error::other)?
            .as_nanos()
    ));
    fs::create_dir(&temporary)?;
    file.seek(SeekFrom::Start(offset))?;
    let decoder = LzmaReader::new_mem_limit(file.take(compressed), 128 * 1024, None)?;
    // 失败保留本次唯一临时目录供排查，不删除或覆盖其他版本。
    unpack(decoder, &temporary, unpacked)
        .map_err(|e| io::Error::other(format!("解压失败（{}）：{e}", temporary.display())))?;
    let mut marker = File::create(temporary.join(".complete"))?;
    marker.write_all(hash.as_bytes())?;
    marker.sync_all()?;
    drop(marker);
    if !complete(&temporary, hash) {
        return Err(invalid("载荷缺少运行文件"));
    }
    fs::rename(&temporary, &root)?;
    Ok(root)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_escaping_and_reserved_paths() {
        for path in [
            "../node.exe",
            "/node.exe",
            "C:/node.exe",
            "a\\b",
            "a//b",
            "a/./b",
            "a/../b",
            "NUL.txt",
            "COM1",
            "a.",
            "a ",
            "x\0y",
        ] {
            assert!(safe_path(path).is_err(), "{path:?}");
        }
        assert_eq!(
            safe_path("src/core/cli.js").unwrap(),
            PathBuf::from("src/core/cli.js")
        );
    }
    #[test]
    fn sha256_matches_known_vector() {
        assert_eq!(
            hash_reader(&b"abc"[..]).unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
    #[test]
    fn malformed_archive_is_rejected_before_filesystem_writes() {
        let root = std::env::temp_dir().join(format!("tl-rejected-payload-{}", std::process::id()));
        assert!(!root.exists());
        let mut excessive_count = ARCHIVE.to_vec();
        excessive_count.extend_from_slice(&10001_u32.to_le_bytes());
        let mut excessive_path = ARCHIVE.to_vec();
        excessive_path.extend_from_slice(&1_u32.to_le_bytes());
        excessive_path.extend_from_slice(&1025_u32.to_le_bytes());
        for bytes in [
            Vec::new(),
            b"BADMAGIC".to_vec(),
            excessive_count,
            excessive_path,
        ] {
            assert!(unpack(bytes.as_slice(), &root, MAX_UNPACKED).is_err());
        }
        assert!(!root.exists());
    }
}
