#import <Cocoa/Cocoa.h>

#include <algorithm>

#include <cinttypes>
#include <cmath>
#include <string>

#include "BridgeCore.h"
#include "BridgeEditor.h"
#include "BridgeRemote.h"
extern "C" {
#include "BridgeDiscovery.h"
}

// The plugin window, in Auraliscope's own look (Sources/Auraliscope/Theme.swift, dark appearance, Sage accent):
// the window gradient, rounded cards, cream ink, expanded-width headings and the hexagon mark. One button
// connects: it launches Auraliscope when needed and makes this insert the active source.
//
// Each binary (VST3, AU) compiles this file with its own class names: a host that loads both formats would
// otherwise see two definitions of one Objective-C class.
#ifndef ABR_EDITOR_CLASS
#error "Define ABR_EDITOR_CLASS"
#endif
#define ABR_JOIN_INNER(a, b) a##b
#define ABR_JOIN(a, b) ABR_JOIN_INNER(a, b)
#define ABR_LOGO_CLASS ABR_JOIN(ABR_EDITOR_CLASS, _Logo)
#define ABR_CARD_CLASS ABR_JOIN(ABR_EDITOR_CLASS, _Card)

static const int32_t kDNSServiceErr_PolicyDenied_ABR = -65570;  // dns_sd.h kDNSServiceErr_PolicyDenied
static NSString *const kAppBundleID = @"com.jinboz.SoundMeterJBZ";

// The network scan: one DNS-SD browser for every plugin window of this binary that asked for it, stopped when the
// last one stops or closes. It only runs on request, so the host's Local Network permission request (macOS asks on
// behalf of the DAW) appears when the person is looking for it, never from an insert in the background.
static AbrBrowser *gBrowser = nullptr;
static int gBrowserUsers = 0;
static void acquireBrowser() { if (gBrowserUsers++ == 0) gBrowser = abr_browser_start(); }
static void releaseBrowser() {
    if (gBrowserUsers > 0 && --gBrowserUsers == 0) { abr_browser_stop(gBrowser); gBrowser = nullptr; }
}

namespace {
NSColor *rgb(double r, double g, double b, double a = 1) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a]; }
// Theme.swift, dark appearance.
NSColor *ink() { return rgb(247 / 255.0, 242 / 255.0, 235 / 255.0); }
NSColor *secondary() { return rgb(247 / 255.0, 242 / 255.0, 235 / 255.0, 0.88); }
NSColor *tertiary() { return rgb(247 / 255.0, 242 / 255.0, 235 / 255.0, 0.62); }
NSColor *windowTop() { return rgb(0.132, 0.141, 0.156); }
NSColor *windowBottom() { return rgb(0.092, 0.098, 0.110); }
NSColor *card() { return rgb(0.170, 0.179, 0.196); }
NSColor *display() { return rgb(0.066, 0.070, 0.079); }
NSColor *accent() { return rgb(0x8B / 255.0, 0x9A / 255.0, 0x6E / 255.0); }  // Sage
NSColor *ochre() { return rgb(0.867, 0.698, 0.376); }
NSColor *ember() { return rgb(0.894, 0.408, 0.357); }
NSColor *slate() { return rgb(0.576, 0.651, 0.675); }
NSColor *heather() { return rgb(0.655, 0.604, 0.733); }
NSColor *darkInk() { return rgb(0.102, 0.110, 0.125); }

NSFont *expanded(CGFloat size, NSFontWeight weight) {
    if (@available(macOS 13.0, *)) return [NSFont systemFontOfSize:size weight:weight width:NSFontWidthExpanded];
    return [NSFont systemFontOfSize:size weight:weight];
}

NSString *text(const std::string &value) { return [NSString stringWithUTF8String:value.c_str()] ?: @""; }

NSString *count(uint64_t frames) {
    if (frames >= 1000000) return [NSString stringWithFormat:@"%.1fM", frames / 1e6];
    if (frames >= 1000) return [NSString stringWithFormat:@"%.1fk", frames / 1e3];
    return [NSString stringWithFormat:@"%" PRIu64, frames];
}

NSTextField *label(NSRect frame, NSFont *font, NSColor *color) {
    NSTextField *field = [NSTextField labelWithString:@""];
    field.frame = frame;
    field.font = font;
    field.textColor = color;
    field.lineBreakMode = NSLineBreakByTruncatingTail;
    return field;
}

// Card headings: uppercase, expanded, tracked, tertiary.
NSTextField *heading(NSRect frame, NSString *title) {
    NSTextField *field = label(frame, expanded(9, NSFontWeightSemibold), tertiary());
    field.attributedStringValue = [[NSAttributedString alloc] initWithString:title attributes:@{
        NSFontAttributeName: expanded(9, NSFontWeightSemibold), NSForegroundColorAttributeName: tertiary(),
        NSKernAttributeName: @1.2}];
    return field;
}
}  // namespace

// The Auraliscope mark (Sources/Auraliscope/Brand.swift): a heavy hexagon ring with a lighter one in its right half.
@interface ABR_LOGO_CLASS : NSView
@end
@implementation ABR_LOGO_CLASS
- (void)drawRect:(NSRect)dirtyRect {
    const CGFloat radius = self.bounds.size.height / std::sqrt(3.0);
    const NSPoint center = NSMakePoint(radius, self.bounds.size.height / 2);
    auto hexagon = [](NSBezierPath *path, NSPoint c, CGFloat r) {
        for (int corner = 0; corner < 6; ++corner) {
            const NSPoint point = NSMakePoint(c.x + r * std::cos(corner * M_PI / 3), c.y + r * std::sin(corner * M_PI / 3));
            if (corner == 0) [path moveToPoint:point]; else [path lineToPoint:point];
        }
        [path closePath];
    };
    NSBezierPath *large = [NSBezierPath bezierPath];
    large.windingRule = NSWindingRuleEvenOdd;
    hexagon(large, center, radius);
    hexagon(large, center, radius * 0.749);
    [ink() setFill];
    [large fill];
    NSBezierPath *small = [NSBezierPath bezierPath];
    small.windingRule = NSWindingRuleEvenOdd;
    const NSPoint smallCenter = NSMakePoint(center.x + radius * 0.4725, center.y);
    hexagon(small, smallCenter, radius * 0.402);
    hexagon(small, smallCenter, radius * 0.275);
    [[ink() colorWithAlphaComponent:0.94] setFill];
    [small fill];
}
@end

@interface ABR_CARD_CLASS : NSView
@end
@implementation ABR_CARD_CLASS
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:12 yRadius:12];
    [card() setFill];
    [shape fill];
    [[ink() colorWithAlphaComponent:0.07] setStroke];
    [shape stroke];
}
@end

@interface ABR_EDITOR_CLASS : NSView <NSTextFieldDelegate>
- (instancetype)initWithCore:(std::shared_ptr<abr::BridgeCore>)core
                  nameEdited:(std::function<void()>)nameEdited
                      format:(NSString *)format;
- (void)shutDown;
@end

// Answers three questions, top to bottom: is this insert the one Auraliscope analyses (and one click makes
// it so); is fresh audio arriving; has the stream been interrupted. The network card sits last: it scans only when
// asked (the DAW's Local Network permission is requested then), pairs an Auraliscope display on the network, and lets
// the person send this insert's results to it instead of to this Mac (Bridge/BRIDGE_NETWORK.md).
static const int kNetworkRows = 3;
@implementation ABR_EDITOR_CLASS {
    std::shared_ptr<abr::BridgeCore> _core;
    std::function<void()> _nameEdited;
    NSString *_format;
    NSTimer *_timer;
    NSTextField *_name, *_headline, *_detail, *_thisMac, *_identity, *_copy, *_rate, *_layout, *_state, *_fresh,
        *_counters, *_networkSummary, *_network[kNetworkRows], *_loudness, *_levels, *_measured;
    NSButton *_connect, *_scan, *_reset, *_pause, *_networkAction[kNetworkRows];
    AbrPeer _rowPeer[kNetworkRows];          // the receiver each row shows
    std::unique_ptr<abr::PairingJob> _pairing;
    NSView *_dot;
    BOOL _scanning, _scanRequested, _launchFailed;
}

- (instancetype)initWithCore:(std::shared_ptr<abr::BridgeCore>)core
                  nameEdited:(std::function<void()>)nameEdited
                      format:(NSString *)format {
    self = [super initWithFrame:NSMakeRect(0, 0, abr::kEditorWidth, abr::kEditorHeight)];
    if (!self) return nil;
    _core = std::move(core);
    _nameEdited = std::move(nameEdited);
    _format = format;
    self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    const CGFloat width = abr::kEditorWidth, margin = 16, inner = width - 2 * margin;

    // Header: mark, name, format and the BETA badge.
    ABR_LOGO_CLASS *logo = [[ABR_LOGO_CLASS alloc] initWithFrame:NSMakeRect(margin, 16, 20 * 2 / std::sqrt(3.0), 20)];
    [self addSubview:logo];
    NSTextField *title = label(NSMakeRect(margin + 32, 14, 250, 22), expanded(15, NSFontWeightSemibold), ink());
    title.stringValue = @"Auraliscope Bridge";
    [self addSubview:title];
    NSTextField *badge = label(NSMakeRect(width - margin - 46, 18, 46, 15), expanded(9, NSFontWeightBold), darkInk());
    badge.stringValue = @"BETA";
    badge.alignment = NSTextAlignmentCenter;
    badge.wantsLayer = YES;
    badge.layer.backgroundColor = ochre().CGColor;
    badge.layer.cornerRadius = 7.5;
    [self addSubview:badge];
    NSTextField *formatLabel = label(NSMakeRect(width - margin - 104, 18, 50, 15), expanded(10, NSFontWeightMedium), tertiary());
    formatLabel.alignment = NSTextAlignmentRight;
    formatLabel.stringValue = format;
    [self addSubview:formatLabel];

    // 1. Is this insert the one analysed? Status, and the one-click button.
    ABR_CARD_CLASS *connection = [[ABR_CARD_CLASS alloc] initWithFrame:NSMakeRect(margin, 48, inner, 112)];
    [self addSubview:connection];
    [connection addSubview:heading(NSMakeRect(14, 11, 200, 12), @"AURALISCOPE")];
    _dot = [[NSView alloc] initWithFrame:NSMakeRect(14, 35, 8, 8)];
    _dot.wantsLayer = YES;
    _dot.layer.cornerRadius = 4;
    [connection addSubview:_dot];
    _headline = label(NSMakeRect(28, 29, inner - 42, 18), [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], ink());
    [connection addSubview:_headline];
    _detail = label(NSMakeRect(28, 48, inner - 42, 16), [NSFont systemFontOfSize:11], secondary());
    [connection addSubview:_detail];
    _thisMac = label(NSMakeRect(28, 64, inner - 42, 14), [NSFont systemFontOfSize:10], tertiary());
    [connection addSubview:_thisMac];
    _connect = [NSButton buttonWithTitle:@"" target:self action:@selector(connect:)];
    _connect.bordered = NO;
    _connect.wantsLayer = YES;
    _connect.layer.cornerRadius = 12;
    _connect.frame = NSMakeRect(inner - 14 - 196, 80, 196, 24);
    [connection addSubview:_connect];

    // 2. Which insert this is: its name (saved with the project) and identity.
    ABR_CARD_CLASS *source = [[ABR_CARD_CLASS alloc] initWithFrame:NSMakeRect(margin, 168, inner, 84)];
    [self addSubview:source];
    [source addSubview:heading(NSMakeRect(14, 11, 200, 12), @"THIS INSERT")];
    // The field sits inset in a display-coloured well, like the meter window's readouts.
    NSView *well = [[NSView alloc] initWithFrame:NSMakeRect(14, 27, inner - 28, 26)];
    well.wantsLayer = YES;
    well.layer.backgroundColor = display().CGColor;
    well.layer.cornerRadius = 7;
    [source addSubview:well];
    _name = [NSTextField textFieldWithString:text(_core->sourceName())];
    _name.frame = NSMakeRect(9, 4, well.frame.size.width - 18, 18);
    _name.bezeled = NO;
    _name.drawsBackground = NO;
    _name.textColor = ink();
    _name.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    _name.focusRingType = NSFocusRingTypeNone;
    _name.delegate = self;
    _name.target = self;
    _name.action = @selector(commitName:);
    _name.toolTip = @"Shown in Auraliscope' source list and saved with the project. Leave empty to use the track name.";
    [well addSubview:_name];
    _identity = label(NSMakeRect(14, 58, inner - 28, 14), [NSFont systemFontOfSize:10], tertiary());
    [source addSubview:_identity];
    _copy = label(NSMakeRect(14, 58, inner - 28, 14), [NSFont systemFontOfSize:10], ochre());
    _copy.hidden = YES;
    [source addSubview:_copy];

    // 3. Is fresh audio arriving, and has the stream been interrupted?
    ABR_CARD_CLASS *stream = [[ABR_CARD_CLASS alloc] initWithFrame:NSMakeRect(margin, 260, inner, 90)];
    [self addSubview:stream];
    [stream addSubview:heading(NSMakeRect(14, 11, 200, 12), @"STREAM")];
    _rate = label(NSMakeRect(14, 26, 110, 22), [NSFont monospacedDigitSystemFontOfSize:17 weight:NSFontWeightMedium], ink());
    [stream addSubview:_rate];
    _layout = label(NSMakeRect(118, 30, 170, 18), [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], secondary());
    [stream addSubview:_layout];
    _state = label(NSMakeRect(inner - 14 - 150, 31, 150, 16), expanded(9, NSFontWeightSemibold), accent());
    _state.alignment = NSTextAlignmentRight;
    [stream addSubview:_state];
    _fresh = label(NSMakeRect(14, 52, inner - 28, 14), [NSFont systemFontOfSize:11], secondary());
    [stream addSubview:_fresh];
    _counters = label(NSMakeRect(14, 69, inner - 28, 14), [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular], tertiary());
    [stream addSubview:_counters];

    // 4. This insert's own measurement: the analysis runs here, in the plugin, whether or not Labs is open.
    ABR_CARD_CLASS *measurement = [[ABR_CARD_CLASS alloc] initWithFrame:NSMakeRect(margin, 358, inner, 88)];
    [self addSubview:measurement];
    [measurement addSubview:heading(NSMakeRect(14, 11, 200, 12), @"MEASUREMENT")];
    _loudness = label(NSMakeRect(14, 26, inner - 28 - 150, 22), [NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightMedium], ink());
    [measurement addSubview:_loudness];
    _levels = label(NSMakeRect(14, 50, inner - 28, 14), [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular], secondary());
    [measurement addSubview:_levels];
    _measured = label(NSMakeRect(14, 67, inner - 28, 14), [NSFont systemFontOfSize:10], tertiary());
    [measurement addSubview:_measured];
    _pause = [NSButton buttonWithTitle:@"" target:self action:@selector(togglePause:)];
    _pause.bordered = NO;
    _pause.wantsLayer = YES;
    _pause.layer.cornerRadius = 10;
    _pause.frame = NSMakeRect(inner - 14 - 144, 26, 70, 20);
    _pause.toolTip = @"Pauses this insert's measurement for every display: audio still passes, and is not measured.";
    [measurement addSubview:_pause];
    _reset = [NSButton buttonWithTitle:@"" target:self action:@selector(resetMeasurement:)];
    _reset.bordered = NO;
    _reset.wantsLayer = YES;
    _reset.layer.cornerRadius = 10;
    _reset.frame = NSMakeRect(inner - 14 - 70, 26, 70, 20);
    _reset.toolTip = @"Starts this insert's measurement afresh (integrated loudness, range, held peaks).";
    [measurement addSubview:_reset];

    // Network: Auraliscope displays on other devices (Auraliscope for iPad). Scanned only on request, so the DAW's
    // Local Network permission is asked for only by someone looking for it.
    ABR_CARD_CLASS *network = [[ABR_CARD_CLASS alloc] initWithFrame:NSMakeRect(margin, 454, inner, 120)];
    [self addSubview:network];
    [network addSubview:heading(NSMakeRect(14, 11, 250, 12), @"NETWORK DISPLAYS")];
    _networkSummary = label(NSMakeRect(14, 28, inner - 28 - 110, 14), [NSFont systemFontOfSize:11], secondary());
    [network addSubview:_networkSummary];
    for (int row = 0; row < kNetworkRows; ++row) {
        _network[row] = label(NSMakeRect(14, 50 + 22 * row, inner - 28 - 92, 14), [NSFont systemFontOfSize:10], tertiary());
        [network addSubview:_network[row]];
        _networkAction[row] = [NSButton buttonWithTitle:@"" target:self action:@selector(networkAction:)];
        _networkAction[row].bordered = NO;
        _networkAction[row].wantsLayer = YES;
        _networkAction[row].layer.cornerRadius = 9;
        _networkAction[row].tag = row;
        _networkAction[row].frame = NSMakeRect(inner - 14 - 84, 47 + 22 * row, 84, 18);
        [network addSubview:_networkAction[row]];
    }
    _scan = [NSButton buttonWithTitle:@"" target:self action:@selector(toggleScan:)];
    _scan.bordered = NO;
    _scan.wantsLayer = YES;
    _scan.layer.cornerRadius = 10;
    _scan.frame = NSMakeRect(inner - 14 - 100, 24, 100, 20);
    [network addSubview:_scan];

    NSTextField *note = label(NSMakeRect(margin, 582, inner, 14), [NSFont systemFontOfSize:10], tertiary());
    note.stringValue = @"Audio passes through unchanged. Closing this window keeps measuring.";
    [self addSubview:note];
    [self refresh];
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:windowTop() endingColor:windowBottom()];
    [gradient drawInRect:self.bounds angle:90];
}

- (void)dealloc {
    [_timer invalidate];
    [self setScanning:NO];
}

// Browses only while the person asked for it and the window is on screen.
- (void)setScanning:(BOOL)scanning {
    if (scanning == _scanning) return;
    _scanning = scanning;
    if (scanning) acquireBrowser(); else releaseBrowser();
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [_timer invalidate];
    _timer = nil;
    [self setScanning:_scanRequested && self.window != nil];
    if (!self.window) return;
    __weak ABR_EDITOR_CLASS *weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *) { [weakSelf refresh]; }];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)shutDown {
    [self setScanning:NO];
    [_timer invalidate];
    _timer = nil;
    _name.delegate = nil;
    _name.target = nil;
    _connect.target = nil;
    _scan.target = nil;
    _reset.target = nil;
    _pause.target = nil;
    for (int row = 0; row < kNetworkRows; ++row) _networkAction[row].target = nil;
    _pairing.reset();   // cancels a pairing in progress
}

// The copy of Auraliscope to launch. Older test builds left in Downloads or a build folder share its bundle ID,
// and Launch Services may pick any of them: take the newest build, and among equal builds one in an Applications
// folder. Copies in the Trash are skipped.
static NSURL *appApplicationURL() {
    auto usable = [](NSURL *url) {
        if (!url || [url.pathComponents containsObject:@".Trash"] || [url.pathComponents containsObject:@".Trashes"])
            return false;
        NSString *executable = [NSBundle bundleWithURL:url].executablePath;
        // Auraliscope before 2.0 (build 91) shares the bundle ID but cannot receive DAW audio.
        return executable && [NSFileManager.defaultManager isExecutableFileAtPath:executable]
            && [[NSBundle bundleWithURL:url].infoDictionary[@"CFBundleVersion"] integerValue] >= 91;
    };
    NSURL *best = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:kAppBundleID];
    if (!usable(best)) best = nil;
    if (@available(macOS 12.0, *)) {
        auto build = [](NSURL *url) {
            return [[NSBundle bundleWithURL:url].infoDictionary[@"CFBundleVersion"] integerValue];
        };
        auto installed = [](NSURL *url) { return [url.path containsString:@"/Applications/"]; };
        NSInteger bestBuild = best ? build(best) : -1;
        for (NSURL *url in [NSWorkspace.sharedWorkspace URLsForApplicationsWithBundleIdentifier:kAppBundleID]) {
            if (!usable(url)) continue;
            const NSInteger candidate = build(url);
            if (candidate > bestBuild || (candidate == bestBuild && installed(url) && !installed(best))) {
                best = url;
                bestBuild = candidate;
            }
        }
    }
    return best;
}

// One click: ask Auraliscope to analyse this insert, launching it first when it is not running. The request
// waits in the core and goes out as soon as the connection is up.
- (void)connect:(id)sender {
    if (_core->status().carrier == abr::Carrier::network) {
        // Back to Auraliscope on this Mac (the person's choice, saved with the project).
        _core->setRemoteReceiver("");
        if (_nameEdited) _nameEdited();
        [self refresh];
        return;
    }
    _core->requestFocus();
    _launchFailed = NO;
    if (!_core->status().connected) {
        NSURL *app = appApplicationURL();
        if (app) {
            NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
            configuration.arguments = @[@"--bridge-launch"];
            configuration.activates = YES;
            [NSWorkspace.sharedWorkspace openApplicationAtURL:app configuration:configuration completionHandler:nil];
        } else {
            _launchFailed = YES;
        }
    }
    [self refresh];
}

- (void)resetMeasurement:(id)sender {
    _core->requestCommand(ABR_COMMAND_RESET);
}

- (void)togglePause:(id)sender {
    _core->requestCommand(_core->status().measurement == ABR_MEASUREMENT_PAUSED ? ABR_COMMAND_RESUME : ABR_COMMAND_PAUSE);
}

// A row's button: send here, stop sending (back to this Mac), or pair.
- (void)networkAction:(NSButton *)sender {
    const NSInteger row = sender.tag;
    if (row < 0 || row >= kNetworkRows) return;
    const AbrPeer peer = _rowPeer[row];
    const std::string id = peer.receiver_id;
    const abr::CoreStatus status = _core->status();
    abr::PairedReceiver paired;
    if (status.remoteID == id) {
        _core->setRemoteReceiver("");
    } else if (abr::findReceiver(id, &paired)) {
        _core->setRemoteReceiver(id);
        if (_nameEdited) _nameEdited();   // the choice is saved with the project
    } else if (peer.pairing_port != 0 && self.window) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [NSString stringWithFormat:@"Pair with “%s”", peer.name];
        alert.informativeText = @"Enter the code the iPad shows (Wireless Display ▸ Pair). Pairing lets this Mac's "
                                 "Auraliscope Bridge send analysis results to it, encrypted. No audio is sent.";
        NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
        field.placeholderString = @"ABCD-EFGH";
        field.font = [NSFont monospacedSystemFontOfSize:15 weight:NSFontWeightMedium];
        alert.accessoryView = field;
        [alert addButtonWithTitle:@"Pair"];
        [alert addButtonWithTitle:@"Cancel"];
        alert.window.initialFirstResponder = field;
        __weak ABR_EDITOR_CLASS *weakSelf = self;
        const std::string host = peer.host, service = peer.name;
        const uint16_t port = peer.pairing_port;
        [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
            ABR_EDITOR_CLASS *editor = weakSelf;
            if (!editor || response != NSAlertFirstButtonReturn) return;
            [editor startPairing:host port:port receiver:id service:service code:field.stringValue.UTF8String ?: ""];
        }];
    }
    [self refresh];
}

- (void)startPairing:(const std::string &)host port:(uint16_t)port receiver:(const std::string &)receiver
             service:(const std::string &)service code:(const std::string &)code {
    _pairing = std::make_unique<abr::PairingJob>(host, port, receiver, service, code, getprogname(), ABR_PLUGIN_VERSION);
    [self refresh];
}

- (void)toggleScan:(id)sender {
    _scanRequested = !_scanRequested;
    [self setScanning:_scanRequested && self.window != nil];
    [self refresh];
}

- (void)commitName:(id)sender {
    const char *value = _name.stringValue.UTF8String ?: "";
    if (_core->sourceName() == value) return;
    _core->setSourceName(value);
    _name.stringValue = text(_core->sourceName());
    if (_nameEdited) _nameEdited();
}

- (void)controlTextDidEndEditing:(NSNotification *)notification { [self commitName:nil]; }

- (void)style:(NSButton *)button title:(NSString *)title filled:(BOOL)filled enabled:(BOOL)enabled size:(CGFloat)size {
    button.enabled = enabled;
    button.hidden = title.length == 0;
    button.layer.backgroundColor = (filled ? accent() : [ink() colorWithAlphaComponent:0.08]).CGColor;
    NSMutableParagraphStyle *centered = [[NSMutableParagraphStyle alloc] init];
    centered.alignment = NSTextAlignmentCenter;
    button.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:size weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: filled ? darkInk() : secondary(), NSParagraphStyleAttributeName: centered}];
}

// Is this insert the one analysed, and if not, what one click does.
- (void)refreshConnection:(const abr::CoreStatus &)status {
    NSRunningApplication *labs = [NSRunningApplication runningApplicationsWithBundleIdentifier:kAppBundleID].firstObject;
    NSDictionary *info = labs ? [NSBundle bundleWithURL:labs.bundleURL].infoDictionary : nil;
    NSString *version = info ? [NSString stringWithFormat:@"%@ build %@", info[@"AuraliscopeVersionLabel"] ?: @"",
                                                          info[@"CFBundleVersion"] ?: @""] : @"";
    const bool fresh = status.secondsSinceProcess >= 0 && status.secondsSinceProcess < 0.5;
    NSColor *dot = slate();
    NSString *headline, *detail, *button = @"";
    BOOL filled = NO, enabled = NO;
    if (status.carrier == abr::Carrier::network) {
        // Sent to a network display the person chose here: Auraliscope on this Mac does not get this insert meanwhile.
        NSString *name = status.remoteName.empty() ? @"the network display" : text(status.remoteName);
        if (status.receiverTooOld || status.receiverTooNew) {
            headline = status.receiverTooOld ? @"The display needs an update" : @"This plugin needs an update";
            detail = [NSString stringWithFormat:@"%@ speaks another Bridge protocol version.", name];
            dot = ember();
        } else if (status.subscribed) {
            headline = [NSString stringWithFormat:@"Shown on %@", name];
            detail = fresh ? @"This insert's results go over the network, not to Auraliscope on this Mac."
                           : @"Shown there · the DAW is not processing this insert.";
            dot = fresh ? accent() : ochre();
        } else if (status.connected) {
            headline = [NSString stringWithFormat:@"Connected to %@", name];
            detail = @"Waiting for it to show this insert (it shows one source at a time).";
            dot = heather();
        } else {
            headline = [NSString stringWithFormat:@"Sending to %@", name];
            detail = [self remoteLine:status];
            dot = status.remoteState == abr::RemoteState::connecting ? slate() : ember();
        }
        _headline.stringValue = headline;
        _detail.stringValue = detail;
        _dot.layer.backgroundColor = dot.CGColor;
        [self style:_connect title:@"Use this Mac" filled:NO enabled:YES size:12];
        _thisMac.stringValue = @"Network display · TLS, paired · results only, no audio";
        return;
    }
    if (status.receiverTooOld) {
        headline = @"Auraliscope needs an update";
        detail = @"The Auraliscope on this Mac is older than this plugin.";
        dot = ember();
    } else if (status.receiverTooNew) {
        headline = @"This plugin needs an update";
        detail = @"Install the Auraliscope Bridge that comes with your Auraliscope.";
        dot = ember();
    } else if (!status.connected) {
        if (status.focusPending) {
            headline = @"Opening Auraliscope…";
            detail = @"This insert is shown as soon as it connects.";
            button = @"Connecting…";
        } else if (_launchFailed) {
            headline = @"Auraliscope is not installed";
            detail = @"Install it in Applications, then click again.";
            dot = ember();
            button = @"Open Auraliscope";
            filled = enabled = YES;
        } else if (labs) {
            headline = @"Connecting to Auraliscope…";
            detail = @"It is starting up.";
        } else {
            headline = @"Auraliscope is not open";
            detail = @"Every insert connects by itself whenever it is open.";
            button = @"Open Auraliscope";
            filled = enabled = YES;
        }
    } else if (status.subscribed) {
        button = @"Shown in Auraliscope";
        switch (status.state) {
        case ABR_STATE_LIVE:
            headline = fresh ? @"Shown in Auraliscope" : @"Selected · no audio";
            detail = fresh ? @"This insert's measurements are shown in Auraliscope."
                           : @"The DAW is not processing this insert (stopped or suspended).";
            dot = fresh ? accent() : ochre();
            break;
        case ABR_STATE_BYPASSED:
            headline = @"Selected · bypassed";
            detail = @"Nothing is measured while the insert is bypassed.";
            dot = ochre();
            break;
        case ABR_STATE_OFFLINE:
            headline = @"Selected · offline render";
            detail = @"A bounce is not metered as live audio.";
            dot = ochre();
            break;
        default:
            headline = @"Selected · inactive";
            detail = @"The DAW has not activated this insert.";
            dot = ochre();
            break;
        }
    } else {
        headline = @"Connected · not analysed";
        detail = @"Auraliscope is showing another source; this insert still measures.";
        dot = heather();
        button = status.focusPending ? @"Switching…" : @"Show this insert";
        filled = enabled = !status.focusPending;
    }
    _headline.stringValue = headline;
    _detail.stringValue = detail;
    _dot.layer.backgroundColor = dot.CGColor;
    [self style:_connect title:button filled:filled enabled:enabled size:12];
    _thisMac.stringValue = labs ? [NSString stringWithFormat:@"This Mac · Auraliscope %@", version]
                                : @"This Mac · Auraliscope not running";
}

// Which insert this is, as Auraliscope lists it.
- (void)refreshIdentity:(const abr::CoreStatus &)status {
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"ID %s", status.instanceTag.c_str()]];
    [parts addObject:_format];
    if (!status.trackName.empty()) [parts addObject:[NSString stringWithFormat:@"track “%@”", text(status.trackName)]];
    _identity.stringValue = [parts componentsJoinedByString:@" · "];
    const bool copy = status.identityFlags & ABR_IDENTITY_COPY;
    _copy.hidden = !copy;
    _identity.hidden = copy;
    if (copy)
        _copy.stringValue = [NSString stringWithFormat:@"ID %s · a copy of #%s with an identity of its own",
                                                       status.instanceTag.c_str(), status.copiedFromTag.c_str()];
    _name.placeholderAttributedString = [[NSAttributedString alloc]
        initWithString:status.trackName.empty() ? [NSString stringWithFormat:@"Auraliscope Bridge %s", status.instanceTag.c_str()]
                                                : text(status.trackName)
            attributes:@{NSForegroundColorAttributeName: tertiary(), NSFontAttributeName: _name.font}];
}

// Is fresh audio arriving, and has the stream been interrupted.
- (void)refreshStream:(const abr::CoreStatus &)status {
    if (status.formatEpoch == 0) {
        _rate.stringValue = @"—";
        _layout.stringValue = @"No stream format yet";
    } else {
        _rate.stringValue = std::fmod(status.sampleRate, 1000) == 0 ? [NSString stringWithFormat:@"%.0f kHz", status.sampleRate / 1000]
                                                                    : [NSString stringWithFormat:@"%.1f kHz", status.sampleRate / 1000];
        const uint32_t kind = status.layout.kind();
        _layout.stringValue = kind == ABR_LAYOUT_MONO ? @"Mono · 32-bit float"
            : kind == ABR_LAYOUT_STEREO ? @"Stereo L R · 32-bit float"
            : kind == ABR_LAYOUT_SPEAKERS ? [NSString stringWithFormat:@"%s · %u ch · 32-bit float", status.layout.name, status.channels]
            : [NSString stringWithFormat:@"%u ch (unsupported)", status.channels];
    }
    switch (status.state) {
    case ABR_STATE_LIVE: _state.stringValue = @"LIVE"; _state.textColor = accent(); break;
    case ABR_STATE_BYPASSED: _state.stringValue = @"BYPASSED · NOT MEASURED"; _state.textColor = ochre(); break;
    case ABR_STATE_OFFLINE: _state.stringValue = @"OFFLINE · NOT MEASURED"; _state.textColor = ochre(); break;
    default: _state.stringValue = @"INACTIVE"; _state.textColor = tertiary(); break;
    }
    const double since = status.secondsSinceProcess;
    if (since < 0) {
        _fresh.stringValue = @"The DAW has not processed this insert yet.";
        _fresh.textColor = tertiary();
    } else if (since < 0.5) {
        NSString *where = !status.subscribed ? @"measured here"
            : status.carrier == abr::Carrier::network ? @"measured here, results sent to the network display"
            : @"measured here, results sent to Auraliscope";
        _fresh.stringValue = [NSString stringWithFormat:@"Audio is flowing · %@", where];
        _fresh.textColor = status.subscribed && status.state == ABR_STATE_LIVE ? accent() : secondary();
    } else {
        _fresh.stringValue = since < 90 ? [NSString stringWithFormat:@"No audio for %.0f s: the DAW is not processing this insert", since]
                                        : @"No audio: the DAW is not processing this insert";
        _fresh.textColor = ochre();
    }
    NSString *transport = !(status.transportFlags & ABR_TRANSPORT_KNOWN) ? @""
        : (status.transportFlags & ABR_TRANSPORT_PLAYING) ? @" · playing" : @" · stopped";
    _counters.stringValue = [NSString stringWithFormat:@"results sent %llu · unanalysed %@ · breaks %u · block ≤ %u%@",
                                                       (unsigned long long)status.resultsSent, count(status.framesDropped),
                                                       status.interruptions, status.maxBlockFrames, transport];
    _counters.textColor = status.framesDropped > 0 || status.interruptions > 0 ? ochre() : tertiary();
    _counters.toolTip = @"Breaks: times the live stream stopped and resumed (bypass, offline render, the DAW idle or "
                        @"restarting the plugin); momentary and short-term loudness restart at each one. Unanalysed: "
                        @"audio the analysis could not keep up with (it still passed through).";
}

static NSString *lufs(float value) { return value <= -99 ? @"—" : [NSString stringWithFormat:@"%.1f", value]; }
static NSString *dbfs(float linear) { return linear <= 1e-6f ? @"−∞" : [NSString stringWithFormat:@"%.1f", 20 * std::log10(linear)]; }

// The insert's own measurement, from its analysis thread.
- (void)refreshMeasurement:(const abr::CoreStatus &)status {
    const bool paused = status.measurement == ABR_MEASUREMENT_PAUSED;
    [self style:_pause title:paused ? @"Resume" : @"Pause" filled:paused enabled:status.measurement != ABR_MEASUREMENT_NONE size:11];
    [self style:_reset title:@"Reset" filled:NO enabled:status.measurement != ABR_MEASUREMENT_NONE size:11];
    if (!status.hasAnalysis) {
        _loudness.stringValue = @"I —  ·  M —  ·  S —";
        _levels.stringValue = status.measurement == ABR_MEASUREMENT_NONE
            ? @"Measures once the DAW plays mono, stereo or immersive audio here." : @"Waiting for audio.";
        _measured.stringValue = @"";
        return;
    }
    const AbrAnalysisSummary &a = status.analysis;
    _loudness.stringValue = [NSString stringWithFormat:@"I %@  ·  M %@  ·  S %@ LUFS", lufs(a.integrated), lufs(a.momentary),
                                                       lufs(a.short_term)];
    NSString *peaks = a.channels > 1 ? [NSString stringWithFormat:@"%@ / %@", dbfs(a.peak[0]), dbfs(a.peak[1])] : dbfs(a.peak[0]);
    NSString *truePeaks = a.channels > 1 ? [NSString stringWithFormat:@"%@ / %@", dbfs(a.held_true_peak[0]), dbfs(a.held_true_peak[1])]
                                         : dbfs(a.held_true_peak[0]);
    NSString *range = a.loudness_range < 0 ? @"—" : [NSString stringWithFormat:@"%.1f LU", a.loudness_range];
    if (a.channels > 2) {
        // An immersive bus: its loudest channel, named (Auraliscope shows every channel).
        _levels.stringValue = [NSString stringWithFormat:@"peak %@ dBFS %s · true peak max %@ dBTP %s · LRA %@",
                                                         dbfs(a.loudest_peak), abr::roleName(a.loudest_peak_role, status.layout),
                                                         dbfs(a.loudest_held_true_peak),
                                                         abr::roleName(a.loudest_held_true_peak_role, status.layout), range];
    } else {
        _levels.stringValue = [NSString stringWithFormat:@"peak %@ dBFS · true peak max %@ dBTP · LRA %@", peaks, truePeaks, range];
    }
    const int seconds = int(a.seconds_analysed);
    NSString *behind = status.backlogMs > 100 ? [NSString stringWithFormat:@" · %u ms behind", status.backlogMs] : @"";
    _measured.stringValue = [NSString stringWithFormat:@"%@%d:%02d measured · %u break%@ · generation %u%@",
                                                       paused ? @"Paused · " : @"", seconds / 60, seconds % 60, a.breaks,
                                                       a.breaks == 1 ? @"" : @"s", a.generation, behind];
    _measured.textColor = paused ? ochre() : tertiary();
}

// The network displays: where this insert's results go, the receivers found, and pairing.
- (void)refreshNetwork:(const abr::CoreStatus &)status {
    [self style:_scan title:_scanRequested ? @"Stop scan" : @"Find displays" filled:NO enabled:YES size:11];
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    int shown = 0;
    if (status.carrier == abr::Carrier::network) {
        _networkSummary.stringValue = [NSString stringWithFormat:@"Results go to “%s”, not to this Mac.",
                                                                 status.remoteName.empty() ? "the network display" : status.remoteName.c_str()];
    } else {
        _networkSummary.stringValue = @"Results go to Auraliscope on this Mac.";
    }
    if (_pairing) {
        const abr::PairingJob::Phase phase = _pairing->phase();
        NSString *line = phase == abr::PairingJob::Phase::connecting ? @"Pairing: connecting…"
            : phase == abr::PairingJob::Phase::waitingForApproval ? @"Pairing: allow this Mac on the iPad…"
            : [NSString stringWithFormat:@"Pairing: %s", _pairing->message().c_str()];
        [rows addObject:line];
        if (phase == abr::PairingJob::Phase::paired || phase == abr::PairingJob::Phase::failed) {
            static int linger = 0;   // keep the outcome on screen a few seconds
            if (++linger > 24) { _pairing.reset(); linger = 0; }
        }
    }
    if (!_scanRequested) {
        if (status.carrier == abr::Carrier::network) [rows addObject:[self remoteLine:status]];
        else if (rows.count == 0) [rows addObject:@"Find displays to send to Auraliscope for iPad, or pair one."];
    } else if (!gBrowser) {
        [rows addObject:@"Network scan unavailable (DNS-SD did not start)."];
    } else if (abr_browser_error(gBrowser) == kDNSServiceErr_PolicyDenied_ABR) {
        [rows addObject:[NSString stringWithFormat:@"Local Network access is off for %@: allow it in System Settings ▸ "
                                                   "Privacy & Security ▸ Local Network.", NSProcessInfo.processInfo.processName]];
    } else {
        AbrPeer peers[16];
        const uint32_t total = std::min<uint32_t>(16, abr_browser_peers(gBrowser, peers, 16));
        for (uint32_t i = 0; i < total && shown < kNetworkRows; ++i) {
            const AbrPeer &peer = peers[i];
            // Displays that take a paired network connection; this Mac's own receivers use the local socket.
            if (!peer.resolved || std::string(peer.role) != "display" || std::string(peer.transport) != "tls-psk"
                || std::strlen(peer.receiver_id) != 32 || (peer.this_mac && std::string(peer.platform) == "macOS")) continue;
            const bool compatible = peer.protocol == ABR_PROTOCOL_VERSION && (peer.schema == 0 || peer.schema == ABR_ANALYSIS_SCHEMA);
            abr::PairedReceiver paired;
            const bool isPaired = abr::findReceiver(peer.receiver_id, &paired);
            const bool current = status.remoteID == peer.receiver_id;
            NSString *state = !compatible ? [NSString stringWithFormat:@"speaks protocol %u, needs an update", peer.protocol]
                : current ? [self remoteLine:status]
                : isPaired ? @"paired"
                : peer.pairing_port ? @"ready to pair" : @"not paired · on the iPad: Wireless Display ▸ Pair";
            _network[shown].stringValue = [NSString stringWithFormat:@"◆  %s · %@", peer.name, state];
            _network[shown].textColor = current ? secondary() : tertiary();
            _rowPeer[shown] = peer;
            NSString *action = !compatible ? @"" : current ? @"Stop" : isPaired ? @"Send here" : peer.pairing_port ? @"Pair…" : @"";
            [self style:_networkAction[shown] title:action filled:(isPaired && !current) enabled:_pairing == nullptr || current size:10];
            ++shown;
        }
        if (shown == 0 && rows.count == 0) [rows addObject:@"Searching the local network for Auraliscope displays…"];
        if (status.carrier == abr::Carrier::network && shown == 0) [rows addObject:[self remoteLine:status]];
    }
    // Rows below the receivers: messages.
    for (int row = shown; row < kNetworkRows; ++row) {
        const int message = row - shown;
        _network[row].stringValue = message < (int)rows.count ? rows[message] : @"";
        _network[row].textColor = tertiary();
        [self style:_networkAction[row] title:@"" filled:NO enabled:NO size:10];
    }
    // While sending to a network display that is not listed, a way back to this Mac.
    if (status.carrier == abr::Carrier::network && shown < kNetworkRows) {
        bool listed = false;
        for (int row = 0; row < shown; ++row) listed = listed || status.remoteID == _rowPeer[row].receiver_id;
        if (!listed) {
            std::memset(&_rowPeer[shown], 0, sizeof(AbrPeer));
            std::snprintf(_rowPeer[shown].receiver_id, sizeof _rowPeer[shown].receiver_id, "%s", status.remoteID.c_str());
            [self style:_networkAction[shown] title:@"Stop" filled:NO enabled:YES size:10];
        }
    }
}

- (NSString *)remoteLine:(const abr::CoreStatus &)status {
    const char *name = status.remoteName.empty() ? "network display" : status.remoteName.c_str();
    switch (status.remoteState) {
    case abr::RemoteState::connected:
        return [NSString stringWithFormat:@"sending to %s · %@B sent", name, count(status.remoteBytesSent)];
    case abr::RemoteState::connecting: return [NSString stringWithFormat:@"connecting to %s…", name];
    case abr::RemoteState::unreachable:
        return [NSString stringWithFormat:@"%s not reachable, retrying (%s)", name, status.remoteDetail.c_str()];
    case abr::RemoteState::refused: return [NSString stringWithFormat:@"%s refused this Mac: pair again", name];
    case abr::RemoteState::notPaired: return @"the chosen display is not paired with this Mac: pair it again";
    case abr::RemoteState::accessDenied:
        return [NSString stringWithFormat:@"Local Network access is off for %@ (System Settings ▸ Privacy & Security)",
                                          NSProcessInfo.processInfo.processName];
    default: return @"";
    }
}

- (void)refresh {
    const abr::CoreStatus status = _core->status();
    [self refreshConnection:status];
    [self refreshIdentity:status];
    [self refreshStream:status];
    [self refreshMeasurement:status];
    [self refreshNetwork:status];
}
@end

namespace abr {

void *createEditorView(std::shared_ptr<BridgeCore> core, std::function<void()> nameEdited, const char *formatLabel) {
    ABR_EDITOR_CLASS *view = [[ABR_EDITOR_CLASS alloc] initWithCore:std::move(core) nameEdited:std::move(nameEdited)
                                                             format:[NSString stringWithUTF8String:formatLabel]];
    return (__bridge_retained void *)view;
}

void attachEditorView(void *view, void *parent) {
    NSView *editor = (__bridge NSView *)view;
    NSView *host = (__bridge NSView *)parent;
    editor.frame = NSMakeRect(0, 0, kEditorWidth, kEditorHeight);
    [host addSubview:editor];
}

void destroyEditorView(void *view) {
    ABR_EDITOR_CLASS *editor = (__bridge_transfer ABR_EDITOR_CLASS *)view;
    [editor shutDown];
    [editor removeFromSuperview];
}

}  // namespace abr
