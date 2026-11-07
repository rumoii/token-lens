use crate::stats::{Error, Result};
use std::io::Read;

fn frame_end(bytes: &[u8], start: usize) -> Result<(usize, bool)> {
    let error = |s: &str| Error(s.into());
    if start + 5 > bytes.len() {
        return Err(error("zstd frame truncated before header"));
    }
    let magic = u32::from_le_bytes(bytes[start..start + 4].try_into().unwrap());
    if (0x184d2a50..=0x184d2a5f).contains(&magic) {
        if start + 8 > bytes.len() {
            return Err(error("zstd skippable frame truncated"));
        }
        let size = u32::from_le_bytes(bytes[start + 4..start + 8].try_into().unwrap()) as usize;
        let end = start + 8 + size;
        if end > bytes.len() {
            return Err(error("zstd skippable frame exceeds buffer"));
        }
        return Ok((end, false));
    }
    if magic != 0xfd2fb528 {
        return Err(Error(format!("zstd magic mismatch at {start}")));
    }
    let descriptor = bytes[start + 4];
    let single = (descriptor >> 5) & 1;
    let mut position = start
        + 5
        + usize::from(single == 0)
        + [0, 1, 2, 4][(descriptor & 3) as usize]
        + [single as usize, 2, 4, 8][(descriptor >> 6) as usize];
    if position > bytes.len() {
        return Err(error("zstd frame header exceeds buffer"));
    }
    loop {
        if position + 3 > bytes.len() {
            return Err(error("zstd block header truncated"));
        }
        let block = bytes[position] as u32
            | (bytes[position + 1] as u32) << 8
            | (bytes[position + 2] as u32) << 16;
        position += 3;
        position += match (block >> 1) & 3 {
            0 | 2 => (block >> 3) as usize,
            1 => 1,
            _ => return Err(error("zstd reserved block type")),
        };
        if position > bytes.len() {
            return Err(error("zstd block exceeds buffer"));
        }
        if block & 1 != 0 {
            break;
        }
    }
    if descriptor & 4 != 0 {
        position += 4;
    }
    if position > bytes.len() {
        return Err(error("zstd checksum truncated"));
    }
    Ok((position, true))
}

pub fn decode(bytes: &[u8]) -> Result<Vec<u8>> {
    let mut position = 0;
    let mut output = Vec::new();
    while position < bytes.len() {
        let (end, standard) = frame_end(bytes, position)?;
        if standard {
            let mut decoder = ruzstd::decoding::StreamingDecoder::new(&bytes[position..end])
                .map_err(|e| Error(format!("zstd: {e}")))?;
            decoder.read_to_end(&mut output)?;
            if let Some(expected) = decoder.decoder.get_checksum_from_data() {
                if decoder.decoder.get_calculated_checksum() != Some(expected) {
                    return Err(Error("zstd checksum mismatch".into()));
                }
            }
        }
        position = end;
    }
    Ok(output)
}
