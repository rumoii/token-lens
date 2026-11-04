#![windows_subsystem = "windows"]

#[cfg(windows)]
mod payload;
mod runtime;

use std::{
    io::{BufRead, BufReader},
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tao::{
    event::{Event, StartCause, WindowEvent},
    event_loop::{ControlFlow, EventLoopBuilder},
    window::WindowBuilder,
};
use wry::{NewWindowResponse, WebContext, WebViewBuilder};

enum KernelEvent {
    Started(runtime::Guard),
    Ready,
    Failed(String),
}

fn page(title: &str, detail: &str) -> String {
    let escape = |s: &str| {
        s.replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
    };
    format!(
        "<!doctype html><html lang=zh-CN><meta charset=utf-8><title>Token Lens</title><style>body{{font:16px system-ui;margin:64px;color:#243342;background:#f7f8fa}}h1{{font-size:24px}}pre{{white-space:pre-wrap;overflow-wrap:anywhere;line-height:1.7}}</style><h1>{}</h1><pre>{}</pre></html>",
        escape(title),
        escape(detail)
    )
}

fn monitor(
    proxy: tao::event_loop::EventLoopProxy<KernelEvent>,
    data: PathBuf,
) -> Result<(), Box<dyn std::error::Error>> {
    let root = runtime::runtime_root()?;
    let runtime::Kernel {
        guard,
        process,
        pid,
        stdout,
        stderr,
    } = runtime::start_kernel(&root, &data)?;
    proxy
        .send_event(KernelEvent::Started(guard))
        .map_err(|_| "窗口已关闭")?;
    let (tx, rx) = std::sync::mpsc::channel();
    let tail = Arc::new(Mutex::new(String::new()));
    let mut readers = Vec::new();
    for (file, is_stdout) in [(stdout, true), (stderr, false)] {
        let tx = tx.clone();
        let tail = tail.clone();
        let data = data.clone();
        readers.push(std::thread::spawn(move || {
            for line in BufReader::new(file).lines() {
                let line = match line {
                    Ok(line) => line,
                    Err(error) => {
                        let _ = tx.send(Err(error.to_string()));
                        break;
                    }
                };
                if is_stdout && line.starts_with("TOKEN_LENS_READY ") {
                    let valid = serde_json::from_str::<serde_json::Value>(&line[17..])
                        .ok()
                        .is_some_and(|v| {
                            v["port"].as_u64() == Some(3456)
                                && v["pid"].as_u64() == Some(pid as u64)
                                && v["data_dir"]
                                    .as_str()
                                    .is_some_and(|dir| PathBuf::from(dir) == data)
                        });
                    let _ = tx.send(if valid {
                        Ok(())
                    } else {
                        Err("内核就绪行格式或字段不正确".into())
                    });
                } else if !is_stdout {
                    let mut buffer = tail.lock().unwrap();
                    buffer.push_str(&line);
                    buffer.push('\n');
                    if buffer.len() > 4096 {
                        let mut offset = buffer.len() - 4096;
                        while !buffer.is_char_boundary(offset) {
                            offset += 1;
                        }
                        buffer.drain(..offset);
                    }
                }
            }
        }));
    }
    drop(tx);
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut ready = false;
    loop {
        if let Some(code) = process.wait(50) {
            // 子进程已关闭管道写端；等待读完 stderr，避免退出事件抢先吞掉端口错误。
            for reader in readers {
                let _ = reader.join();
            }
            return Err(format!("内核已退出（exit {code}）。\n{}", tail.lock().unwrap()).into());
        }
        if let Ok(result) = rx.try_recv() {
            result.map_err(|reason| format!("启动失败：{reason}"))?;
            if !ready {
                proxy
                    .send_event(KernelEvent::Ready)
                    .map_err(|_| "窗口已关闭")?;
                ready = true;
            }
        }
        if !ready && Instant::now() >= deadline {
            process.terminate();
            return Err(format!("内核在 30 秒内未就绪，已终止。\n{}", tail.lock().unwrap()).into());
        }
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let Some(instance) = runtime::single_instance()? else {
        return Ok(());
    };
    let data = runtime::data_dir()?;
    let event_loop = EventLoopBuilder::<KernelEvent>::with_user_event().build();
    let window = WindowBuilder::new()
        .with_title("Token Lens")
        .with_inner_size(tao::dpi::LogicalSize::new(1180.0, 820.0))
        .build(&event_loop)?;
    let mut context = WebContext::new(Some(data.join("webview")));
    let webview = WebViewBuilder::new_with_web_context(&mut context)
        .with_html(page("正在启动 Token Lens…", "正在准备本地内核，请稍候。"))
        .with_navigation_handler(|url| {
            if url == "about:blank" {
                return true;
            }
            let local = url == "http://127.0.0.1:3456"
                || url.starts_with("http://127.0.0.1:3456/")
                || url.starts_with("http://127.0.0.1:3456?")
                || url.starts_with("http://127.0.0.1:3456#");
            if !local {
                runtime::open_external(&url);
            }
            local
        })
        .with_new_window_req_handler(|url, _| {
            runtime::open_external(&url);
            NewWindowResponse::Deny
        })
        .build(&window)?;
    let proxy = event_loop.create_proxy();
    let worker_data = data.clone();
    std::thread::spawn(move || {
        if let Err(error) = monitor(proxy.clone(), worker_data) {
            let _ = proxy.send_event(KernelEvent::Failed(error.to_string()));
        }
    });
    let mut guard = None;
    event_loop.run(move |event, _, control_flow| {
        // 这些资源由窗口生命周期持有；LoopDestroyed 显式释放内核守卫。
        let _ = (&instance, &context);
        *control_flow = ControlFlow::Wait;
        match event {
            Event::NewEvents(StartCause::Init) => runtime::install_menu(),
            Event::UserEvent(KernelEvent::Started(handle)) => guard = Some(handle),
            Event::UserEvent(KernelEvent::Ready) => {
                if let Err(error) = webview.load_url("http://127.0.0.1:3456/") {
                    let _ = webview.load_html(&page("页面加载失败", &error.to_string()));
                }
            }
            Event::UserEvent(KernelEvent::Failed(reason)) => {
                drop(guard.take());
                let detail = format!(
                    "{reason}\n\n请检查端口 3456 是否已被其他程序占用。\n日志：{}",
                    data.join("logs").display()
                );
                if webview
                    .load_html(&page("Token Lens 启动失败", &detail))
                    .is_err()
                {
                    runtime::show_error(&detail);
                }
            }
            Event::WindowEvent {
                event: WindowEvent::CloseRequested,
                ..
            } => {
                drop(guard.take());
                *control_flow = ControlFlow::Exit;
            }
            Event::LoopDestroyed => drop(guard.take()),
            _ => {}
        }
    })
}

fn main() {
    if let Err(error) = run() {
        runtime::show_error(&format!("Token Lens 无法启动：{error}"));
    }
}
