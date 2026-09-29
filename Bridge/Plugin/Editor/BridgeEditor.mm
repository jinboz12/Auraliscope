#import <Cocoa/Cocoa.h>

#include <algorithm>

#include <cinttypes>
#include <cmath>
#include <string>

#include "BridgeCore.h"
#include "BridgeEditor.h"
extern "C" {
#include "BridgeDiscovery.h"
}

// The plugin window, in Auraliscope's own look (Sources/Auraliscope/Theme.swift, dark appearance, Sage accent):
// the window gradient, rounded cards, cream ink, expanded-width headings and the hexagon mark. One button
// connects: it launches Auraliscope Labs when needed and makes this insert the active source.
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
static NSString *const kLabsBundleID = @"com.jinboz.SoundMeterJBZ.Labs";
static NSString *const kReleaseBundleID = @"com.jinboz.SoundMeterJBZ";

// The network scan: one DNS-SD browser for every open plugin window of this binary, stopped when the last one
// closes. It only runs while a window is open, so the host's Local Network permission request (macOS asks on
// behalf of the DAW) appears when the user is looking at the plugin, never from an insert in the background.
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

@implementation ABR_EDITOR_CLASS {
    std::shared_ptr<abr::BridgeCore> _core;
    std::function<void()> _nameEdited;
    NSTimer *_timer;
    NSTextField *_name, *_connection, *_detail, *_rate, *_layout, *_state, *_counters, *_thisMac, *_network[3];
    BOOL _scanning;
    NSButton *_connect;
    NSView *_dot;
    BOOL _launchFailed;
}

- (instancetype)initWithCore:(std::shared_ptr<abr::BridgeCore>)core
                  nameEdited:(std::function<void()>)nameEdited
                      format:(NSString *)format {
    self = [super initWithFrame:NSMakeRect(0, 0, abr::kEditorWidth, abr::kEditorHeight)];
    if (!self) return nil;
    _core = std::move(core);
    _nameEdited = std::move(nameEdited);
    self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    const CGFloat width = abr::kEditorWidth, margin = 16, inner = width - 2 * margin;

    // Header: mark, name, format and the LABS badge.
    ABR_LOGO_CLASS *logo = [[ABR_LOGO_CLASS alloc] initWithFrame:NSMakeRect(margin, 16, 20 * 2 / std::sqrt(3.0), 20)];
    [self addSubview:logo];
    NSTextField *title = label(NSMakeRect(margin + 32, 14, 250, 22), expanded(15, NSFontWeightSemibold), ink());
    title.stringValue = @"Auraliscope Bridge";
    [self addSubview:title];
    NSTextField *badge = label(NSMakeRect(width - margin - 46, 18, 46, 15), expanded(9, NSFontWeightBold), darkInk());
    badge.stringValue = @"LABS";
    badge.alignment = NSTextAlignmentCenter;
    badge.wantsLayer = YES;
    badge.layer.backgroundColor = ochre().CGColor;
    badge.layer.cornerRadius = 7.5;
    [self addSubview:badge];
    NSTextField *formatLabel = label(NSMakeRect(width - margin - 104, 18, 50, 15), expanded(10, NSFontWeightMedium), tertiary());
    formatLabel.alignment = NSTextAlignmentRight;
    formatLabel.stringValue = format;
    [self addSubview:formatLabel];

    // Connection card: status and the one-click button.
    ABR_CARD_CLASS *connection = [[ABR_CARD_CLASS alloc] initWithFrame:NSMakeRect(margin, 48, inner, 98)];
    [self addSubview:connection];
    [connection addSubview:heading(NSMakeRect(14, 11, 200, 12), @"AURALISCOPE LABS")];
    _dot = [[NSView alloc] initWithFrame:NSMakeRect(14, 35, 8, 8)];
    _dot.wantsLayer = YES;
    _dot.layer.cornerRadius = 4;
    [connection addSubview:_dot];
    _connection = label(NSMakeRect(28, 29, inner - 42, 18), [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], ink());
    [connection addSubview:_connection];
    _detail = label(NSMakeRect(28, 48, inner - 42, 16), [NSFont systemFontOfSize:11], secondary());
    [connection addSubview:_detail];
    _connect = [NSButton buttonWithTitle:@"" target:self action:@selector(connect:)];
    _connect.bordered = NO;
    _connect.wantsLayer = YES;
    _connect.layer.cornerRadius = 12;
    _connect.frame = NSMakeRect(inner - 14 - 212, 66, 212, 24);
    [connection addSubview:_connect];

    // Scan card: Auraliscope on this Mac, and receivers on the local network (a future Auraliscope for iOS).
    ABR_CARD_CLASS *scan = [[ABR_CARD_CLASS alloc] initWithFrame:NSMakeRect(margin, 154, inner, 100)];
    [self addSubview:scan];
    [scan addSubview:heading(NSMakeRect(14, 11, inner - 28, 12), @"FOUND ON THIS MAC AND NETWORK")];
    _thisMac = label(NSMakeRect(14, 28, inner - 28, 16), [NSFont systemFontOfSize:11 weight:NSFontWeightMedium], ink());
    [scan addSubview:_thisMac];
    for (int row = 0; row < 3; ++row) {
        _network[row] = label(NSMakeRect(14, 46 + 17 * row, inner - 28, 16), [NSFont systemFontOfSize:11], secondary());
        [scan addSubview:_network[row]];
    }

    // Source card: the editable name.
    ABR_CARD_CLASS *source = [[ABR_CARD_CLASS alloc] initWithFrame:NSMakeRect(margin, 262, inner, 66)];
    [self addSubview:source];
    [source addSubview:heading(NSMakeRect(14, 11, 200, 12), @"SOURCE NAME")];
    // The field sits inset in a display-coloured well, like the meter window's readouts.
    NSView *well = [[NSView alloc] initWithFrame:NSMakeRect(14, 29, inner - 28, 26)];
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
    _name.toolTip = @"Shown in Auraliscope's source list and saved with the project. Leave empty to use the track name.";
    [well addSubview:_name];

    // Stream card: value and unit, as the meter window's heading shows them, and the state.
    ABR_CARD_CLASS *stream = [[ABR_CARD_CLASS alloc] initWithFrame:NSMakeRect(margin, 336, inner, 76)];
    [self addSubview:stream];
    [stream addSubview:heading(NSMakeRect(14, 11, 200, 12), @"STREAM")];
    _rate = label(NSMakeRect(14, 28, 110, 22), [NSFont monospacedDigitSystemFontOfSize:17 weight:NSFontWeightMedium], ink());
    [stream addSubview:_rate];
    _layout = label(NSMakeRect(118, 32, 170, 18), [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], secondary());
    [stream addSubview:_layout];
    _state = label(NSMakeRect(inner - 14 - 150, 33, 150, 16), expanded(9, NSFontWeightSemibold), accent());
    _state.alignment = NSTextAlignmentRight;
    [stream addSubview:_state];
    _counters = label(NSMakeRect(14, 53, inner - 28, 14), [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular], tertiary());
    [stream addSubview:_counters];

    NSTextField *note = label(NSMakeRect(margin, 420, inner, 14), [NSFont systemFontOfSize:10], tertiary());
    note.stringValue = @"Audio passes through unchanged. Closing this window does not stop the stream.";
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

- (void)setScanning:(BOOL)scanning {
    if (scanning == _scanning) return;
    _scanning = scanning;
    if (scanning) acquireBrowser(); else releaseBrowser();
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [_timer invalidate];
    _timer = nil;
    [self setScanning:self.window != nil];
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
}

// One click: ask Auraliscope Labs to show this insert, launching it first when it is not running. The request
// waits in the core and goes out as soon as the connection is up.
- (void)connect:(id)sender {
    _core->requestFocus();
    _launchFailed = NO;
    if (!_core->status().connected) {
        NSURL *app = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:kLabsBundleID];
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

- (void)commitName:(id)sender {
    const char *value = _name.stringValue.UTF8String ?: "";
    if (_core->sourceName() == value) return;
    _core->setSourceName(value);
    _name.stringValue = text(_core->sourceName());
    if (_nameEdited) _nameEdited();
}

- (void)controlTextDidEndEditing:(NSNotification *)notification { [self commitName:nil]; }

- (void)setButton:(NSString *)title filled:(BOOL)filled enabled:(BOOL)enabled {
    _connect.enabled = enabled;
    _connect.layer.backgroundColor = (filled ? accent() : [ink() colorWithAlphaComponent:0.08]).CGColor;
    NSMutableParagraphStyle *centered = [[NSMutableParagraphStyle alloc] init];
    centered.alignment = NSTextAlignmentCenter;
    _connect.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: filled ? darkInk() : secondary(), NSParagraphStyleAttributeName: centered}];
}

// This Mac: the Bridge socket says whether Auraliscope Labs is connected; the running applications say whether it
// is starting, and whether only the release Auraliscope (which does not receive DAW audio yet) is open.
// The network: DNS-SD peers other than this Mac's own macOS receivers.
- (void)refreshScan:(const abr::CoreStatus &)status {
    NSRunningApplication *labs = [NSRunningApplication runningApplicationsWithBundleIdentifier:kLabsBundleID].firstObject;
    NSString *version = labs ? ([NSBundle bundleWithURL:labs.bundleURL].infoDictionary[@"AuraliscopeVersionLabel"] ?: @"") : @"";
    if (status.connected) {
        _thisMac.stringValue = [NSString stringWithFormat:@"●  This Mac · Auraliscope Labs %@ · connected", version];
        _thisMac.textColor = ink();
    } else if (labs) {
        _thisMac.stringValue = [NSString stringWithFormat:@"●  This Mac · Auraliscope Labs %@ · running, connecting…", version];
        _thisMac.textColor = ink();
    } else if ([NSRunningApplication runningApplicationsWithBundleIdentifier:kReleaseBundleID].count) {
        _thisMac.stringValue = @"●  This Mac · Auraliscope is open, but only Auraliscope Labs receives DAW audio";
        _thisMac.textColor = ochre();
    } else {
        _thisMac.stringValue = @"○  This Mac · Auraliscope Labs is not running";
        _thisMac.textColor = secondary();
    }

    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    if (!gBrowser) {
        [rows addObject:@"Network scan unavailable (DNS-SD did not start)"];
    } else if (abr_browser_error(gBrowser) == kDNSServiceErr_PolicyDenied_ABR) {
        [rows addObject:[NSString stringWithFormat:@"Local network access is off for %@:", NSProcessInfo.processInfo.processName]];
        [rows addObject:@"allow it in System Settings ▸ Privacy & Security ▸ Local Network"];
    } else {
        AbrPeer peers[16];
        const uint32_t count = std::min<uint32_t>(16, abr_browser_peers(gBrowser, peers, 16));
        for (uint32_t i = 0; i < count && rows.count < 3; ++i) {
            const AbrPeer &peer = peers[i];
            if (peer.this_mac && std::string(peer.platform) == "macOS") continue;  // this Mac's own receiver
            NSString *what = peer.resolved ? [NSString stringWithFormat:@"%s for %s %s", peer.app, peer.platform, peer.version]
                                           : @"resolving…";
            [rows addObject:[NSString stringWithFormat:@"◆  %s · %@%@", peer.name, what, peer.this_mac ? @" (this Mac)" : @""]];
        }
        if (rows.count == 0) [rows addObject:@"Searching the local network for Auraliscope on iPhone and iPad…"];
        else if (rows.count < 3) [rows addObject:@"iPhone and iPad are listed for now; streaming to them comes later."];
    }
    for (int row = 0; row < 3; ++row) {
        _network[row].stringValue = row < (int)rows.count ? rows[row] : @"";
        _network[row].textColor = [rows[MIN(row, (int)rows.count - 1)] hasPrefix:@"◆"] ? secondary() : tertiary();
    }
}

- (void)refresh {
    const abr::CoreStatus status = _core->status();
    _name.placeholderAttributedString = [[NSAttributedString alloc]
        initWithString:status.trackName.empty() ? [NSString stringWithFormat:@"Auraliscope Bridge %s", status.instanceTag.c_str()]
                                                : text(status.trackName)
            attributes:@{NSForegroundColorAttributeName: tertiary(), NSFontAttributeName: _name.font}];

    NSColor *dot;
    if (!status.connected) {
        _connection.stringValue = status.focusPending ? @"Opening Auraliscope Labs…" : @"Not connected";
        _detail.stringValue = _launchFailed ? @"Auraliscope Labs is not installed on this Mac."
                                            : @"It connects by itself whenever Auraliscope Labs is open.";
        dot = _launchFailed ? ember() : slate();
        [self setButton:status.focusPending ? @"Connecting…" : @"Open Auraliscope Labs" filled:!status.focusPending
                enabled:!status.focusPending];
    } else if (status.subscribed) {
        const bool live = status.state == ABR_STATE_LIVE;
        _connection.stringValue = live ? @"Streaming to Auraliscope Labs" : @"Selected in Auraliscope Labs";
        _detail.stringValue = @"This insert is the active source.";
        dot = live ? accent() : ochre();
        [self setButton:@"Showing in Auraliscope Labs" filled:NO enabled:NO];
    } else {
        _connection.stringValue = @"Connected to Auraliscope Labs";
        _detail.stringValue = @"Auraliscope Labs is showing another source.";
        dot = heather();
        [self setButton:status.focusPending ? @"Connecting…" : @"Show in Auraliscope Labs" filled:!status.focusPending
                enabled:!status.focusPending];
    }
    _dot.layer.backgroundColor = dot.CGColor;

    if (status.formatEpoch == 0) {
        _rate.stringValue = @"—";
        _layout.stringValue = @"No stream format yet";
    } else {
        _rate.stringValue = std::fmod(status.sampleRate, 1000) == 0 ? [NSString stringWithFormat:@"%.0f kHz", status.sampleRate / 1000]
                                                                    : [NSString stringWithFormat:@"%.1f kHz", status.sampleRate / 1000];
        _layout.stringValue = status.channels == 1 ? @"Mono · 32-bit float"
            : status.channels == 2 ? @"Stereo L R · 32-bit float" : [NSString stringWithFormat:@"%u ch (unsupported)", status.channels];
    }
    switch (status.state) {
    case ABR_STATE_LIVE: _state.stringValue = @"LIVE"; _state.textColor = accent(); break;
    case ABR_STATE_BYPASSED: _state.stringValue = @"BYPASSED · NOT SENT"; _state.textColor = ochre(); break;
    case ABR_STATE_OFFLINE: _state.stringValue = @"OFFLINE RENDER · NOT SENT"; _state.textColor = ochre(); break;
    default: _state.stringValue = @"INACTIVE"; _state.textColor = tertiary(); break;
    }
    [self refreshScan:status];
    NSString *transport = !(status.transportFlags & ABR_TRANSPORT_KNOWN) ? @""
        : (status.transportFlags & ABR_TRANSPORT_PLAYING) ? @" · playing" : @" · stopped";
    _counters.stringValue = [NSString stringWithFormat:@"sent %@ · dropped %@ · block ≤ %u · ID %s%@", count(status.framesSent),
                                                       count(status.framesDropped), status.maxBlockFrames,
                                                       status.instanceTag.c_str(), transport];
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
