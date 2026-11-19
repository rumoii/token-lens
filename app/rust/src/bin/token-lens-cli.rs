fn main() -> std::process::ExitCode {
    std::process::ExitCode::from(rust_lib_token_lens::cli::run(std::env::args_os().skip(1)))
}
