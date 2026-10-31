//! Where the data comes from, as its licences ask.
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const cards = @import("cards.zig");

const credits = [_][2][]const u8{
    .{ "Bus arrivals", "Contains information from LTA DataMall's Bus Arrival API, accessed live, made available under the terms of the Singapore Open Data Licence version 1.0. Passed through by arrivelah (arrivelah2.busrouter.sg)." },
    .{ "Stops, services and routes", "Contains information from LTA DataMall made available under the terms of the Singapore Open Data Licence version 1.0, as compiled by busrouter.sg (data.busrouter.sg/v1) and bundled with the app." },
    .{ "MRT and LRT", "Stations and their exits contain information from LTA DataMall and data.gov.sg, made available under the terms of the Singapore Open Data Licence version 1.0, as compiled by sgraildata (github.com/cheeaun/sgraildata). Track lengths are measured on its line shapes (CityMapper, © OpenStreetMap contributors). Train times and waits are our estimates, not a timetable." },
    .{ "Place search and transit routing", "OneMap, Singapore Land Authority. Results © SLA, under the OneMap terms of use." },
    .{ "Ways there", "Bus and MRT ways from OneMap when it has a token; otherwise planned on this phone over the stop and station lists above, bus and train, with estimated ride times. Bus waits are live when LTA has them." },
    .{ "Map", "Apple Maps (MapKit)." },
    .{ "Built with", "nanoui: Zig, Metal and UIKit, no Swift." },
};

pub fn view(c: *ui.Context) void {
    ui.text(c, "About", .{ .size = 28, .weight = .semibold, .color = cards.ink });
    for (credits, 0..) |cr, i| {
        c.next_key_int = i;
        const card = ui.div(c).column().wFull().rounded(22).bg(.white).p(16).gap(4);
        ui.text(c, cr[0], .{ .size = 17, .weight = .semibold, .color = cards.ink });
        ui.text(c, cr[1], .{ .size = 13, .color = cards.gray, .wrap = true });
        card.end();
    }
}
