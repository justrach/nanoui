//! Headless-ish iced twin of the nanoui hill-climb scenes.
//! Uses iced's tiny-skia (CPU) backend under Xvfb when a window is required.
use std::time::{Duration, Instant};

use iced::widget::{column, container, row, scrollable, text, Space};
use iced::{time, Color, Element, Length, Subscription, Task, Theme};

fn median(xs: &mut [f64]) -> f64 {
    xs.sort_by(|a, b| a.partial_cmp(b).unwrap());
    xs[xs.len() / 2]
}

#[derive(Clone, Debug)]
enum Message {
    Tick,
}

struct Bench {
    scene: String,
    frame: usize,
    warmup: usize,
    measured: usize,
    times: Vec<f64>,
}

impl Bench {
    fn new(scene: String, frames: usize) -> Self {
        Self {
            scene,
            frame: 0,
            warmup: 30,
            measured: frames,
            times: Vec::with_capacity(frames),
        }
    }

    fn title(&self) -> String {
        format!("iced-nanoui-bench {}", self.scene)
    }

    fn update(&mut self, _: Message) -> Task<Message> {
        // Time widget-tree build (layout/present are inside iced's window
        // and are not hooked). Interval-between-ticks was ~0 and discarded.
        let t0 = Instant::now();
        let _ = self.view();
        let ms = t0.elapsed().as_secs_f64() * 1000.0;
        if self.frame >= self.warmup && self.times.len() < self.measured {
            self.times.push(ms);
        }
        self.frame += 1;
        if self.times.len() >= self.measured {
            let mut times = std::mem::take(&mut self.times);
            let p50 = median(&mut times);
            let ops = match self.scene.as_str() {
                "boxes" => 600,
                "springs" => 2000,
                "text" => 300,
                "scroll" => 1000,
                _ => 0,
            };
            println!(
                "{{\"framework\":\"iced\",\"scene\":\"{}\",\"frames\":{},\"frame_ms_p50\":{p50:.4},\"ops\":{ops},\"renderer\":\"tiny-skia\",\"present\":\"widget tree only (no present timestamp)\"}}",
                self.scene,
                self.measured
            );
            let _ = std::io::Write::flush(&mut std::io::stdout());
            std::process::exit(0);
        }
        Task::none()
    }

    fn subscription(&self) -> Subscription<Message> {
        time::every(Duration::from_millis(1)).map(|_| Message::Tick)
    }

    fn view(&self) -> Element<'_, Message> {
        match self.scene.as_str() {
            "text" => text_scene(self.frame),
            "springs" => springs_scene(self.frame),
            "scroll" => scroll_scene(self.frame),
            _ => boxes_scene(self.frame),
        }
    }
}

fn hsl(h: f32) -> Color {
    let h = ((h % 360.0) + 360.0) % 360.0;
    let s = 0.7f32;
    let l = 0.55f32;
    let f = |n: f32| {
        let k = (n + h / 30.0) % 12.0;
        let a = s * l.min(1.0 - l);
        l - a * ((k - 3.0).min(9.0 - k).min(1.0).max(-1.0))
    };
    Color::from_rgb(f(0.0), f(8.0), f(4.0))
}

fn boxes_scene(frame: usize) -> Element<'static, Message> {
    let t = frame as f32 / 120.0;
    let mut rows = Vec::new();
    for r in 0..20 {
        let mut cells = Vec::new();
        for c in 0..30 {
            let i = (r * 30 + c) as f32;
            let y = 6.0 * (t * 3.0 + i * 0.1).sin();
            cells.push(
                container(Space::new(24.0, 24.0))
                    .width(24)
                    .height(24)
                    .style(move |_| container::Style {
                        background: Some(hsl(t * 60.0 + i * 3.0).into()),
                        border: iced::Border {
                            radius: 6.0.into(),
                            ..Default::default()
                        },
                        shadow: iced::Shadow {
                            color: Color::from_rgba(0.0, 0.0, 0.0, 0.2),
                            offset: iced::Vector::new(0.0, 2.0 + y),
                            blur_radius: 4.0,
                        },
                        ..Default::default()
                    })
                    .into(),
            );
        }
        rows.push(row(cells).spacing(4).into());
    }
    column(rows).spacing(4).padding(10).into()
}

fn springs_scene(frame: usize) -> Element<'static, Message> {
    let t = frame as f32 / 120.0;
    let mut rows = Vec::new();
    for r in 0..40 {
        let mut cells = Vec::new();
        for c in 0..50 {
            let i = (r * 50 + c) as f32;
            let y = 4.0 * (t * 3.0 + i * 0.1).sin();
            cells.push(
                container(Space::new(14.0, 14.0))
                    .width(14)
                    .height(14)
                    .style(move |_| container::Style {
                        background: Some(Color::from_rgb(0.31, 0.55, 0.86).into()),
                        border: iced::Border {
                            radius: 3.0.into(),
                            ..Default::default()
                        },
                        shadow: iced::Shadow {
                            color: Color::TRANSPARENT,
                            offset: iced::Vector::new(0.0, y),
                            blur_radius: 0.0,
                        },
                        ..Default::default()
                    })
                    .into(),
            );
        }
        rows.push(row(cells).spacing(2).into());
    }
    column(rows).spacing(2).padding(8).into()
}

fn text_scene(frame: usize) -> Element<'static, Message> {
    let mut rows = Vec::new();
    for r in 0..15 {
        let mut cells = Vec::new();
        for c in 0..20 {
            let i = r * 20 + c;
            let n = (frame * 7 + i * 13) % 10000;
            cells.push(text(format!("{n}")).size(13).into());
        }
        rows.push(row(cells).spacing(4).into());
    }
    column(rows).spacing(6).padding(10).into()
}

fn scroll_scene(frame: usize) -> Element<'static, Message> {
    let _ = frame;
    let mut rows = Vec::new();
    for i in 0..1000 {
        rows.push(
            row![
                text(format!("Row {i} — a line of a long list")).size(13),
                Space::new(Length::Fill, 1),
                text(format!("{}", i * 7 % 100)).size(12),
            ]
            .height(28)
            .spacing(8)
            .into(),
        );
    }
    scrollable(column(rows)).height(Length::Fill).into()
}

fn main() -> iced::Result {
    let scene = std::env::args().nth(1).unwrap_or_else(|| "boxes".into());
    let frames: usize = std::env::args()
        .nth(2)
        .and_then(|s| s.parse().ok())
        .unwrap_or(20);
    iced::application(Bench::title, Bench::update, Bench::view)
        .subscription(Bench::subscription)
        .theme(|_| Theme::Light)
        .window_size((900.0, 640.0))
        .run_with(move || (Bench::new(scene, frames), Task::none()))
}
