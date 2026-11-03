//! Slint software-renderer twin of the nanoui hill-climb scenes.
use std::rc::Rc;
use std::time::{Duration, Instant};

use slint::{Timer, TimerMode};

fn median(xs: &mut [f64]) -> f64 {
    xs.sort_by(|a, b| a.partial_cmp(b).unwrap());
    xs[xs.len() / 2]
}

slint::slint! {
    export component Bench inherits Window {
        in-out property <int> frame: 0;
        in-out property <string> scene: "boxes";
        width: 900px;
        height: 640px;
        background: #f5f5f7;

        if scene == "boxes": VerticalLayout {
            padding: 10px;
            spacing: 4px;
            for r in 20: HorizontalLayout {
                spacing: 4px;
                for c in 30: Rectangle {
                    property <float> i: r * 30 + c;
                    property <float> t: frame / 120.0;
                    width: 24px;
                    height: 24px;
                    border-radius: 6px;
                    y: 6px * sin((t * 3 + i * 0.1) * 1rad);
                    background: hsv(mod(t * 60 + i * 3, 360), 0.7, 0.85);
                    drop-shadow-blur: 4px;
                    drop-shadow-offset-y: 2px;
                    drop-shadow-color: #00000033;
                }
            }
        }

        if scene == "text": VerticalLayout {
            padding: 10px;
            spacing: 6px;
            for r in 15: HorizontalLayout {
                spacing: 4px;
                for c in 20: Text {
                    width: 40px;
                    font-size: 13px;
                    text: mod(frame * 7 + (r * 20 + c) * 13, 10000);
                    color: #1a1a1a;
                }
            }
        }

        if scene == "springs": VerticalLayout {
            padding: 8px;
            spacing: 2px;
            for r in 40: HorizontalLayout {
                spacing: 2px;
                for c in 50: Rectangle {
                    property <float> i: r * 50 + c;
                    property <float> t: frame / 120.0;
                    width: 14px;
                    height: 14px;
                    border-radius: 3px;
                    y: 4px * sin((t * 3 + i * 0.1) * 1rad);
                    background: #508cdc;
                }
            }
        }

        if scene == "scroll": Flickable {
            width: 100%;
            height: 100%;
            content-y: -mod(frame / 120.0 * 600, 28 * 1000 - 640) * 1px;
            VerticalLayout {
                for i in 1000: HorizontalLayout {
                    height: 28px;
                    padding-left: 12px;
                    spacing: 8px;
                    Text { text: "Row " + i + " — a line of a long list"; font-size: 13px; color: #1a1a1a; }
                    Text { text: mod(i * 7, 100); font-size: 12px; color: #666666; }
                }
            }
        }
    }
}

fn main() {
    let scene = std::env::args().nth(1).unwrap_or_else(|| "boxes".into());
    let frames: usize = std::env::args()
        .nth(2)
        .and_then(|s| s.parse().ok())
        .unwrap_or(20);
    let ui = Bench::new().unwrap();
    ui.set_scene(scene.clone().into());
    let warmup = 30usize;
    let times = Rc::new(std::cell::RefCell::new(Vec::<f64>::new()));
    let last = Rc::new(std::cell::RefCell::new(None::<Instant>));
    let timer = Timer::default();
    let ui_weak = ui.as_weak();
    timer.start(TimerMode::Repeated, Duration::from_millis(1), {
        let times = times.clone();
        let last = last.clone();
        move || {
            let Some(ui) = ui_weak.upgrade() else { return };
            let now = Instant::now();
            if let Some(prev) = *last.borrow() {
                let f = ui.get_frame() as usize;
                if f >= warmup && times.borrow().len() < frames {
                    times
                        .borrow_mut()
                        .push(now.duration_since(prev).as_secs_f64() * 1000.0);
                }
            }
            *last.borrow_mut() = Some(now);
            ui.set_frame(ui.get_frame() + 1);
            if times.borrow().len() >= frames {
                let mut xs = times.borrow().clone();
                let p50 = median(&mut xs);
                let ops = match scene.as_str() {
                    "boxes" => 600,
                    "springs" => 2000,
                    "text" => 300,
                    "scroll" => 1000,
                    _ => 0,
                };
                println!(
                    "{{\"framework\":\"slint\",\"scene\":\"{scene}\",\"frames\":{frames},\"frame_ms_p50\":{p50:.4},\"ops\":{ops},\"renderer\":\"software\",\"present\":\"xvfb + slint software renderer\"}}"
                );
                slint::quit_event_loop().ok();
            }
        }
    });
    ui.run().unwrap();
}
