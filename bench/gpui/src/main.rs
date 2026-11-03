//! Headless / Xvfb twin of nanoui hill-climb scenes, in GPUI 0.2.2.
//!
//! Modes:
//!   test   — TestAppContext + Window::draw (layout, prepaint, paint, scene;
//!            TestWindow discards GPU present). Always available.
//!   linux  — Application::new() on the real X11 backend; Blade presents
//!            through Vulkan. Intended for `xvfb-run` + lavapipe (llvmpipe).
//!   auto   — linux when DISPLAY is set, else test.
use std::time::Instant;

use gpui::{
    Application, Bounds, Context, Render, TestAppContext, Window, WindowBounds, WindowOptions, div,
    prelude::*, px, rgb, size,
};

mod scenes;
use scenes::{HEIGHT, Scene, WIDTH};

fn median(xs: &mut [f64]) -> f64 {
    xs.sort_by(|a, b| a.partial_cmp(b).unwrap());
    xs[xs.len() / 2]
}

fn p95(xs: &mut [f64]) -> f64 {
    xs.sort_by(|a, b| a.partial_cmp(b).unwrap());
    xs[(xs.len() * 95 / 100).min(xs.len() - 1)]
}

struct Bench {
    scene: Scene,
    frame: usize,
    warmup: usize,
    measured: usize,
    times: Vec<f64>,
    last: Option<Instant>,
    done: bool,
    /// When set, each render() requests another frame (Linux/Blade present).
    live: bool,
}

impl Bench {
    fn new(scene: Scene, frames: usize, live: bool) -> Self {
        Self {
            scene,
            frame: 0,
            warmup: 30,
            measured: frames,
            times: Vec::with_capacity(frames),
            last: None,
            done: false,
            live,
        }
    }

    fn tick_live(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let now = Instant::now();
        if let Some(prev) = self.last {
            if self.frame >= self.warmup && self.times.len() < self.measured {
                self.times
                    .push(now.duration_since(prev).as_secs_f64() * 1000.0);
            }
        }
        self.last = Some(now);
        self.frame += 1;
        if self.times.len() < self.measured {
            // X11's refresh timer skips a draw unless the window is dirty.
            window.request_animation_frame();
            cx.notify();
        } else if !self.done {
            self.done = true;
            print_row(
                self.scene,
                self.measured,
                &mut self.times,
                "blade-vulkan",
                &detect_present(),
            );
            let _ = std::io::Write::flush(&mut std::io::stdout());
            std::process::exit(0);
        }
    }
}

impl Render for Bench {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.live {
            self.tick_live(window, cx);
        }
        div()
            .size_full()
            .bg(rgb(0xf5f5f7))
            .child(scenes::render(self.scene, self.frame))
    }
}

fn print_row(scene: Scene, frames: usize, times: &mut [f64], renderer: &str, present: &str) {
    let p50 = median(times);
    let hi = p95(times);
    println!(
        "{{\"framework\":\"gpui\",\"scene\":\"{}\",\"frames\":{frames},\"frame_ms_p50\":{p50:.4},\"frame_ms_p95\":{hi:.4},\"ops\":{},\"renderer\":\"{renderer}\",\"present\":\"{present}\"}}",
        scene.name(),
        scene.ops()
    );
}

fn run_test(scene: Scene, frames: usize) {
    let mut cx = TestAppContext::single();
    let (view, vcx) = cx.add_window_view(|_, _| Bench::new(scene, frames, false));
    vcx.simulate_resize(size(px(WIDTH), px(HEIGHT)));
    let warmup = 30;
    let mut times = vec![0.0; frames];
    for i in 0..warmup + frames {
        view.update(vcx, |v, _cx| {
            v.frame = i;
        });
        vcx.update(|_window, cx| {
            view.update(cx, |_v, cx| cx.notify());
        });
        let t0 = Instant::now();
        vcx.update(|window, cx| {
            let _ = window.draw(cx);
        });
        if i >= warmup {
            times[i - warmup] = t0.elapsed().as_secs_f64() * 1000.0;
        }
    }
    print_row(
        scene,
        frames,
        &mut times,
        "gpui-test",
        "discarded (TestWindow::draw is empty)",
    );
}

fn run_linux(scene: Scene, frames: usize) {
    Application::new().run(move |cx| {
        let bounds = Bounds::centered(None, size(px(WIDTH), px(HEIGHT)), cx);
        let window = cx
            .open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(bounds)),
                    focus: false,
                    show: true,
                    ..Default::default()
                },
                |_, cx| cx.new(|_| Bench::new(scene, frames, false)),
            )
            .expect("GPUI Linux window (need DISPLAY + Vulkan; use xvfb-run + lavapipe)");
        eprintln!(
            "gpui linux: X11 window open ({}); timing Window::draw (Blade present is not pumped: Xvfb vsync/present hung on lavapipe)",
            detect_present()
        );
        let warmup = 30;
        let mut times = vec![0.0; frames];
        for i in 0..warmup + frames {
            window
                .update(cx, |view, _, cx| {
                    view.frame = i;
                    cx.notify();
                })
                .expect("update frame");
            let t0 = Instant::now();
            // Draw from the App, not from inside Entity::update — render()
            // updates the root view and would otherwise nest.
            cx.update_window(window.into(), |_, win, cx| {
                let _ = win.draw(cx);
            })
            .expect("linux draw");
            if i >= warmup {
                times[i - warmup] = t0.elapsed().as_secs_f64() * 1000.0;
            }
        }
        print_row(
            scene,
            frames,
            &mut times,
            "blade-x11",
            &format!(
                "{} — Window::draw on the real X11/Blade window; GPU present not included (lavapipe present hung)",
                detect_present()
            ),
        );
        let _ = std::io::Write::flush(&mut std::io::stdout());
        // X11/calloop quit() does not return under this Xvfb + lavapipe setup.
        std::process::exit(0);
    });
}

fn detect_present() -> String {
    let icd = std::env::var("VK_ICD_FILENAMES")
        .or_else(|_| std::env::var("VK_DRIVER_FILES"))
        .unwrap_or_default();
    let display = std::env::var("DISPLAY").unwrap_or_default();
    if icd.contains("lvp") || icd.contains("llvmpipe") {
        format!("xvfb/x11 + lavapipe (llvmpipe) DISPLAY={display}")
    } else if !display.is_empty() {
        format!("x11 DISPLAY={display} vulkan ICD={icd}")
    } else {
        "no DISPLAY".into()
    }
}

fn vulkan_ready() -> bool {
    std::env::var_os("DISPLAY").is_some()
        && (std::path::Path::new("/usr/share/vulkan/icd.d/lvp_icd.json").exists()
            || std::env::var_os("VK_ICD_FILENAMES").is_some()
            || std::env::var_os("VK_DRIVER_FILES").is_some())
}

fn main() {
    let mut args = std::env::args().skip(1);
    let mut mode = String::from("auto");
    let mut scene = String::from("boxes");
    let mut frames: usize = 20;
    while let Some(a) = args.next() {
        match a.as_str() {
            "--mode" => mode = args.next().unwrap_or(mode),
            "--scene" => scene = args.next().unwrap_or(scene),
            "--frames" => {
                frames = args
                    .next()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(frames)
            }
            other if !other.starts_with('-') => scene = other.to_string(),
            _ => {}
        }
    }
    let scene = Scene::parse(&scene);
    let use_linux = match mode.as_str() {
        "linux" => true,
        "test" => false,
        _ => vulkan_ready(),
    };
    if use_linux {
        run_linux(scene, frames);
    } else {
        run_test(scene, frames);
    }
}
