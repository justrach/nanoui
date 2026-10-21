//! Same hill-climb scenes as `hillclimb/src/scenes.zig`, in GPUI.
use gpui::{
    BoxShadow, Div, FontWeight, ScrollStrategy, SharedString, StyledText,
    UniformListScrollHandle, div, hsla, point, prelude::*, px, rgb, uniform_list,
};

pub const WIDTH: f32 = 900.0;
pub const HEIGHT: f32 = 640.0;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Scene {
    Boxes,
    Text,
    Scroll,
    List,
    Dashboard,
    Springs,
    Letters,
}

impl Scene {
    pub fn parse(s: &str) -> Self {
        match s {
            "text" => Self::Text,
            "scroll" => Self::Scroll,
            "list" => Self::List,
            "dashboard" => Self::Dashboard,
            "springs" => Self::Springs,
            "letters" => Self::Letters,
            _ => Self::Boxes,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Boxes => "boxes",
            Self::Text => "text",
            Self::Scroll => "scroll",
            Self::List => "list",
            Self::Dashboard => "dashboard",
            Self::Springs => "springs",
            Self::Letters => "letters",
        }
    }

    pub fn ops(self) -> usize {
        match self {
            Self::Boxes => 600,
            Self::Text => 300,
            Self::Scroll => 1000,
            Self::List => 40,
            Self::Dashboard => 12,
            Self::Springs => 2000,
            Self::Letters => 16,
        }
    }
}

pub fn render(scene: Scene, frame: usize) -> Div {
    let t = frame as f32 / 120.0;
    match scene {
        Scene::Boxes => boxes(t),
        Scene::Text => text(frame),
        Scene::Scroll => scroll(t),
        Scene::List => list(frame),
        Scene::Dashboard => dashboard(t, frame),
        Scene::Springs => springs(t),
        Scene::Letters => letters(frame),
    }
}

fn hsl(h: f32) -> gpui::Hsla {
    hsla(((h % 360.0) + 360.0) % 360.0 / 360.0, 0.7, 0.55, 1.0)
}

fn box_shadow(a: f32, blur: f32, y: f32) -> Vec<BoxShadow> {
    vec![BoxShadow {
        color: hsla(0.0, 0.0, 0.0, a),
        offset: point(px(0.0), px(y)),
        blur_radius: px(blur),
        spread_radius: px(0.0),
    }]
}

fn boxes(t: f32) -> Div {
    let mut col = div().flex().flex_col().size_full().p(px(10.0)).gap(px(4.0));
    for r in 0..20 {
        let mut row = div().flex().flex_row().gap(px(4.0));
        for c in 0..30 {
            let i = (r * 30 + c) as f32;
            let y = 6.0 * (t * 3.0 + i * 0.1).sin();
            row = row.child(
                div()
                    .w(px(24.0))
                    .h(px(24.0))
                    .rounded(px(6.0))
                    .bg(hsl(t * 60.0 + i * 3.0))
                    .shadow(box_shadow(0.2, 4.0, 2.0))
                    .mt(px(y)),
            );
        }
        col = col.child(row);
    }
    col
}

fn text(frame: usize) -> Div {
    let mut col = div().flex().flex_col().size_full().p(px(10.0)).gap(px(6.0));
    for r in 0..15 {
        let mut row = div().flex().flex_row().gap(px(4.0));
        for c in 0..20 {
            let i = r * 20 + c;
            let n = (frame * 7 + i * 13) % 10000;
            row = row.child(
                div()
                    .w(px(40.0))
                    .text_sm()
                    .text_color(rgb(0x1a1a1a))
                    .child(format!("{n}")),
            );
        }
        col = col.child(row);
    }
    col
}

fn scroll(t: f32) -> Div {
    let offset = ((t * 600.0) as i32).rem_euclid(28 * 1000 - 640);
    let mut inner = div().flex().flex_col().mt(px(-(offset as f32)));
    for i in 0..1000 {
        inner = inner.child(
            div()
                .flex()
                .flex_row()
                .w_full()
                .h(px(28.0))
                .px(px(12.0))
                .items_center()
                .gap(px(8.0))
                .child(
                    div()
                        .text_sm()
                        .text_color(rgb(0x1a1a1a))
                        .child(format!("Row {i} — a line of a long list")),
                )
                .child(div().flex_1())
                .child(
                    div()
                        .text_xs()
                        .text_color(rgb(0x666666))
                        .child(format!("{}", i * 7 % 100)),
                ),
        );
    }
    div()
        .size_full()
        .overflow_hidden()
        .child(inner)
}

fn list(frame: usize) -> Div {
    let rows = 100_000usize;
    let row = (frame * 3) % (rows - 40);
    let handle = UniformListScrollHandle::default();
    handle.scroll_to_item(row, ScrollStrategy::Top);
    div().size_full().child(
        uniform_list("rows", rows, move |range, _window, _cx| {
            range
                .map(|i| {
                    div()
                        .id(i)
                        .flex()
                        .flex_row()
                        .w_full()
                        .h(px(28.0))
                        .px(px(12.0))
                        .items_center()
                        .gap(px(8.0))
                        .child(
                            div()
                                .text_sm()
                                .text_color(rgb(0x1a1a1a))
                                .child(format!("Row {i} — a line of a long list")),
                        )
                        .child(div().flex_1())
                        .child(
                            div()
                                .text_xs()
                                .text_color(rgb(0x666666))
                                .child(format!("{}", i * 7 % 100)),
                        )
                })
                .collect::<Vec<_>>()
        })
        .h_full()
        .track_scroll(handle),
    )
}

fn dashboard(t: f32, frame: usize) -> Div {
    let mut col = div().flex().flex_col().size_full().p(px(16.0)).gap(px(12.0));
    for r in 0..3 {
        let mut row = div().flex().flex_row().gap(px(12.0));
        for c in 0..4 {
            let i = r * 4 + c;
            let v = 0.5 + 0.5 * (t * 2.0 + i as f32).sin();
            let n = (v * 1000.0) as u32;
            row = row.child(
                div()
                    .flex()
                    .flex_col()
                    .w(px(200.0))
                    .p(px(14.0))
                    .gap(px(8.0))
                    .rounded(px(12.0))
                    .bg(rgb(0xffffff))
                    .shadow(box_shadow(0.12, 16.0, 4.0))
                    .child(
                        div()
                            .text_sm()
                            .text_color(rgb(0x333333))
                            .child(format!("Metric {i}")),
                    )
                    .child(
                        div()
                            .text_color(rgb(0x111111))
                            .font_weight(FontWeight::BOLD)
                            .child(format!("{n}")),
                    )
                    .child(
                        div()
                            .w(px(172.0))
                            .h(px(6.0))
                            .rounded(px(3.0))
                            .bg(rgb(0xe0e0e5))
                            .child(
                                div()
                                    .w(px(172.0 * v))
                                    .h(px(6.0))
                                    .rounded(px(3.0))
                                    .bg(rgb(0x0a84ff)),
                            ),
                    )
                    .child(
                        div()
                            .text_xs()
                            .text_color(rgb(0x888888))
                            .child(format!("updated {}s ago", frame % 60)),
                    ),
            );
        }
        col = col.child(row);
    }
    col
}

/// Closed-form spring, same defaults as nanoui `ui.motion` (k=240, c=26, m=1).
fn spring_y(x0: f32, seconds: f32) -> f32 {
    let k = 240.0f32;
    let c = 26.0f32;
    let omega = (k).sqrt();
    let decay = c / 2.0;
    let disc = decay * decay - omega * omega;
    if disc < 0.0 {
        let f = (-disc).sqrt();
        let e = (-decay * seconds).exp();
        e * (x0 * (f * seconds).cos())
    } else {
        let root = disc.sqrt();
        let slow = -omega * omega / (decay + root);
        let fast = -decay - root;
        let se = (slow * seconds).exp();
        let fe = (fast * seconds).exp();
        x0 * 0.5 * (se + fe)
    }
}

fn springs(t: f32) -> Div {
    let mut col = div().flex().flex_col().size_full().p(px(8.0)).gap(px(2.0));
    for r in 0..40 {
        let mut row = div().flex().flex_row().gap(px(2.0));
        for c in 0..50 {
            let n = r * 50 + c;
            let i = n as f32;
            let target = 4.0 * (t * 3.0 + i * 0.1).sin();
            // Displacement from the previous target; dt is one 120 Hz tick.
            let y = target + spring_y(-0.15 * (t * 3.0 + i * 0.1).cos(), 1.0 / 120.0);
            row = row.child(
                div()
                    .id(n)
                    .w(px(14.0))
                    .h(px(14.0))
                    .rounded(px(3.0))
                    .bg(hsl(t * 60.0 + i * 3.0))
                    .mt(px(y)),
            );
        }
        col = col.child(row);
    }
    col
}

fn letters(frame: usize) -> Div {
    let lines = [
        "Springs keep their speed when the target turns",
        "Tweens ease from where they are, not from the start",
        "Presence waits for a box to leave before it is gone",
        "Layout glides a shuffled row to its new place",
        "Letters enter one after another, then sit still",
    ];
    let round = frame / 45;
    let mut col = div().flex().flex_col().size_full().p(px(16.0)).gap(px(10.0));
    for (i, line) in lines.iter().enumerate() {
        let mut row = div().flex().flex_row().id(SharedString::from(format!("L{i}-{round}")));
        for (k, ch) in line.chars().enumerate() {
            let delay = k as f32 * 0.012;
            let local = ((frame as f32 / 120.0) - delay).clamp(0.0, 0.25) / 0.25;
            let ease = 1.0 - (1.0 - local).powi(3);
            let y = 8.0 * (1.0 - ease);
            let opacity = ease;
            row = row.child(
                div()
                    .opacity(opacity)
                    .mt(px(y))
                    .text_color(rgb(0x1a1a1a))
                    .child(StyledText::new(ch.to_string())),
            );
        }
        col = col.child(row);
    }
    col
}

