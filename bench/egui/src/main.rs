//! Headless egui twin of nanoui hill-climb scenes: 600 moving boxes,
//! a text grid, a long scroll, and 2 000 animated rects. No window.
use std::time::Instant;

fn median(xs: &mut [f64]) -> f64 {
    xs.sort_by(|a, b| a.partial_cmp(b).unwrap());
    xs[xs.len() / 2]
}

fn run(scene: &str, frames: usize) -> (f64, usize) {
    let mut ctx = egui::Context::default();
    let mut times = vec![0.0; frames];
    let mut ops = 0usize;
    for i in 0..30 + frames {
        let raw = egui::RawInput::default();
        let t0 = Instant::now();
        let out = ctx.run(raw, |ctx| {
            egui::CentralPanel::default().show(ctx, |ui| match scene {
                "boxes" => boxes(ui, i),
                "text" => text(ui, i),
                "springs" => springs(ui, i),
                _ => scroll(ui, i),
            });
        });
        let ms = t0.elapsed().as_secs_f64() * 1000.0;
        if i >= 30 {
            times[i - 30] = ms;
            ops = out.shapes.len();
        }
    }
    (median(&mut times), ops)
}

fn boxes(ui: &mut egui::Ui, frame: usize) {
    let t = frame as f32 / 120.0;
    ui.spacing_mut().item_spacing = egui::vec2(4.0, 4.0);
    for r in 0..20 {
        ui.horizontal(|ui| {
            for c in 0..30 {
                let i = (r * 30 + c) as f32;
                let y = 6.0 * (t * 3.0 + i * 0.1).sin();
                let hue = ((t * 60.0 + i * 3.0) % 360.0) / 360.0;
                let color = egui::Color32::from_rgb(
                    (hue * 255.0) as u8,
                    140,
                    200,
                );
                let (rect, _) = ui.allocate_exact_size(egui::vec2(24.0, 24.0), egui::Sense::hover());
                ui.painter().rect_filled(rect.translate(egui::vec2(0.0, y)), 6.0, color);
            }
        });
    }
}

fn text(ui: &mut egui::Ui, frame: usize) {
    for r in 0..15 {
        ui.horizontal(|ui| {
            for c in 0..20 {
                let i = r * 20 + c;
                ui.label(format!("{}", (frame * 7 + i * 13) % 10000));
            }
        });
    }
}

fn springs(ui: &mut egui::Ui, frame: usize) {
    let t = frame as f32 / 120.0;
    ui.spacing_mut().item_spacing = egui::vec2(2.0, 2.0);
    for r in 0..40 {
        ui.horizontal(|ui| {
            for c in 0..50 {
                let i = (r * 50 + c) as f32;
                let y = 4.0 * (t * 3.0 + i * 0.1).sin();
                let (rect, _) = ui.allocate_exact_size(egui::vec2(14.0, 14.0), egui::Sense::hover());
                ui.painter().rect_filled(
                    rect.translate(egui::vec2(0.0, y)),
                    3.0,
                    egui::Color32::from_rgb(80, 140, 220),
                );
            }
        });
    }
}

fn scroll(ui: &mut egui::Ui, frame: usize) {
    let offset = ((frame as f32 / 120.0) * 600.0) % (28.0 * 1000.0 - 640.0);
    egui::ScrollArea::vertical()
        .vertical_scroll_offset(offset)
        .show(ui, |ui| {
            for i in 0..1000 {
                ui.horizontal(|ui| {
                    ui.label(format!("Row {i} — a line of a long list"));
                    ui.label(format!("{}", i * 7 % 100));
                });
            }
        });
}

fn main() {
    let scene = std::env::args().nth(1).unwrap_or_else(|| "boxes".into());
    let frames: usize = std::env::args()
        .nth(2)
        .and_then(|s| s.parse().ok())
        .unwrap_or(40);
    let (ms, ops) = run(&scene, frames);
    println!("{{\"framework\":\"egui\",\"scene\":\"{scene}\",\"frames\":{frames},\"frame_ms_p50\":{ms:.4},\"ops\":{ops},\"renderer\":\"cpu\"}}");
}
