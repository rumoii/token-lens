use lzma_rust2::{LzmaOptions, LzmaWriter};
use std::{
    fs::File,
    io::{self, BufReader, BufWriter},
};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() != 2 {
        return Err("Usage: pack <archive> <archive.lzma>".into());
    }
    let input = File::open(&args[0])?;
    let mut options = LzmaOptions::with_preset(9);
    options.nice_len = 273;
    options.dict_size = 64 * 1024 * 1024;
    let mut writer = LzmaWriter::new_use_header(
        BufWriter::new(File::create(&args[1])?),
        &options,
        Some(input.metadata()?.len()),
    )?;
    io::copy(&mut BufReader::new(input), &mut writer)?;
    std::io::Write::flush(&mut writer.finish()?)?;
    Ok(())
}
