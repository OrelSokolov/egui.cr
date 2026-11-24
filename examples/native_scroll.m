// Native macOS scrolling oracle: NSScrollView + striped document view.
// Record/Stop/Save buttons capture the touchpad event stream (with the
// precise/phase/momentum flags) and the real scroll offset sampled on a
// 120 Hz timer into JSON — the oracle timeline egui_scroll's recording
// is compared against. Recording starts with a strip pass: everything
// before the last >=1 s idle gap is dropped, so idle pre-history never
// pollutes the capture.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

#define REC_PATH "/Users/oleg/egui.cr/tmp/scroll_native.json"

static double rec_now(void) { return CACurrentMediaTime(); }

@interface RecEntry : NSObject
@property double t, sy, sx;
@property int precise, phase, momentum;
@end
@implementation RecEntry
@end

@interface OffEntry : NSObject
@property double t, y;
@end
@implementation OffEntry
@end

@interface StripedView : NSView
@property CGFloat rowH;
@end

@implementation StripedView
- (void)drawRect:(NSRect)dirty {
    [[NSColor windowBackgroundColor] set];
    NSRectFill(dirty);
    CGFloat h = self.rowH;
    NSIndexSet *rows = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(
        (NSUInteger)floorf(dirty.origin.y / h),
        (NSUInteger)ceilf(dirty.size.height / h) + 1)];
    [rows enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *_){BOOL stop; (void)stop;
        NSRect r = NSMakeRect(0, i * h, self.bounds.size.width, h - 2);
        NSColor *c = (i % 2) ? [NSColor controlBackgroundColor]
                             : [NSColor colorWithCalibratedRed:0.85 green:0.90 blue:1.0 alpha:1.0];
        [c set];
        NSRectFill(r);
        NSString *label = [NSString stringWithFormat:@"row %lu", (unsigned long)i];
        [label drawAtPoint:NSMakePoint(12, i * h + (h - 14) / 2)
            withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:13],
                             NSForegroundColorAttributeName: [NSColor labelColor]}];
    }];
}
- (void)scrollWheel:(NSEvent *)e {
    // pass through to NSScrollView first, then log with the real
    // application time — the event itself is never modified.
    [super scrollWheel:e];
    id dlg = NSApp.delegate;
    if ([dlg respondsToSelector:@selector(logScrollEvent:)])
        [dlg performSelector:@selector(logScrollEvent:) withObject:e];
}
- (BOOL)isFlipped { return YES; }
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSWindow *win;
@property (strong) NSScrollView *sv;
@property (strong) NSButton *btnRec, *btnStop, *btnSave;
@property (strong) NSTextField *status;
@property (strong) NSTimer *sampler;
@property (nonatomic) BOOL recording;
@property (strong) NSMutableArray<RecEntry *> *events;
@property (strong) NSMutableArray<OffEntry *> *offsets;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    (void)n;
    self.events = [NSMutableArray array];
    self.offsets = [NSMutableArray array];
    self.recording = NO;

    NSRect frame = NSMakeRect(0, 0, 520, 640);
    self.win = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                  NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    [self.win setTitle:@"native scroll oracle"];
    [self.win center];

    // --- header: buttons + status (outside the scroll view) ----------
    NSView *header = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 44)];
    CGFloat bx = 12;
    SEL acts[3] = {@selector(doRecord:), @selector(doStop:), @selector(doSave:)};
    NSString *titles[3] = {@"Record", @"Stop", @"Save"};
    for (int i = 0; i < 3; i++) {
        NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(bx, 8, 84, 28)];
        b.title = titles[i];
        b.bezelStyle = NSBezelStyleRounded;
        b.target = self;
        b.action = acts[i];
        [header addSubview:b];
        if (i == 0) self.btnRec = b;
        if (i == 1) self.btnStop = b;
        if (i == 2) self.btnSave = b;
        bx += 92;
    }
    self.status = [[NSTextField alloc] initWithFrame:NSMakeRect(bx + 8, 12, 520 - bx - 20, 22)];
    self.status.editable = NO;
    self.status.bordered = NO;
    self.status.backgroundColor = nil;
    self.status.stringValue = @"idle";
    [header addSubview:self.status];

    // --- scroll view with the striped document ------------------------
    StripedView *doc = [[StripedView alloc] initWithFrame:NSMakeRect(0, 0, 500, 200 * 28)];
    doc.rowH = 28;
    self.sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 520, 640 - 44)];
    self.sv.documentView = doc;
    self.sv.hasVerticalScroller = YES;
    self.sv.autohidesScrollers = NO;
    self.sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSView *content = [[NSView alloc] initWithFrame:frame];
    self.sv.frame = NSMakeRect(0, 0, 520, 640 - 44);
    [content addSubview:self.sv];
    [content addSubview:header];
    header.autoresizingMask = NSViewWidthSizable;
    // pin header on top, scroll view fills the rest
    self.sv.translatesAutoresizingMaskIntoConstraints = NO;
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [content addConstraints:@[
        [NSLayoutConstraint constraintWithItem:header attribute:NSLayoutAttributeTop
          relatedBy:NSLayoutRelationEqual toItem:content attribute:NSLayoutAttributeTop
          multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:header attribute:NSLayoutAttributeWidth
          relatedBy:NSLayoutRelationEqual toItem:content attribute:NSLayoutAttributeWidth
          multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:header attribute:NSLayoutAttributeHeight
          relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute
          multiplier:1 constant:44],
        [NSLayoutConstraint constraintWithItem:self.sv attribute:NSLayoutAttributeTop
          relatedBy:NSLayoutRelationEqual toItem:header attribute:NSLayoutAttributeBottom
          multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:self.sv attribute:NSLayoutAttributeBottom
          relatedBy:NSLayoutRelationEqual toItem:content attribute:NSLayoutAttributeBottom
          multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:self.sv attribute:NSLayoutAttributeWidth
          relatedBy:NSLayoutRelationEqual toItem:content attribute:NSLayoutAttributeWidth
          multiplier:1 constant:0],
    ]];
    self.win.contentView = content;

    [self.btnStop setEnabled:NO];
    [self.win makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

// --- recording -------------------------------------------------------

- (void)logScrollEvent:(NSEvent *)e {
    if (!self.recording) return;
    RecEntry *r = [RecEntry new];
    r.t = rec_now();
    r.sy = e.scrollingDeltaY;
    r.sx = e.scrollingDeltaX;
    r.precise = e.hasPreciseScrollingDeltas ? 1 : 0;
    r.phase = (int)e.phase;
    r.momentum = (int)e.momentumPhase;
    [self.events addObject:r];
    // an offset sample right at the event grounds the two curves
    [self addOffsetSample];
}

- (void)addOffsetSample {
    // documentVisibleRect — the actual viewport origin the scroll
    // bar/trackpad drive; doc.bounds.origin never moves on scroll.
    double y = self.sv.documentVisibleRect.origin.y;
    OffEntry *o = [OffEntry new];
    o.t = rec_now();
    o.y = y;
    [self.offsets addObject:o];
}

- (void)tick:(NSTimer *)timer {
    (void)timer;
    if (self.recording) [self addOffsetSample];
}

// strip: drop everything before the last >=1 s idle gap (pre-record
// idle history never pollutes the capture)
- (void)strip {
    NSMutableArray *times = [NSMutableArray array];
    for (RecEntry *e in self.events) [times addObject:@(e.t)];
    for (OffEntry *o in self.offsets) [times addObject:@(o.t)];
    [times sortUsingSelector:@selector(compare:)];
    if (times.count < 2) return;
    double cut = -1;
    for (NSUInteger i = 0; i + 1 < times.count; i++)
        if ([times[i + 1] doubleValue] - [times[i] doubleValue] >= 1.0)
            cut = [times[i] doubleValue];
    if (cut < 0) return;
    NSMutableArray *e2 = [NSMutableArray array];
    for (RecEntry *e in self.events) if (e.t > cut) [e2 addObject:e];
    NSMutableArray *o2 = [NSMutableArray array];
    for (OffEntry *o in self.offsets) if (o.t > cut) [o2 addObject:o];
    self.events = e2;
    self.offsets = o2;
}

- (void)doRecord:(id)sender {
    (void)sender;
    [self strip];
    self.recording = YES;
    [self.btnRec setEnabled:NO];
    [self.btnStop setEnabled:YES];
    self.status.stringValue = [NSString stringWithFormat:
        @"recording… (stripped to %lu ev / %lu off)",
        (unsigned long)self.events.count, (unsigned long)self.offsets.count];
    self.sampler = [NSTimer timerWithTimeInterval:1.0 / 120.0
        target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.sampler forMode:NSRunLoopCommonModes];
}

- (void)doStop:(id)sender {
    (void)sender;
    self.recording = NO;
    [self.sampler invalidate];
    self.sampler = nil;
    [self.btnRec setEnabled:YES];
    [self.btnStop setEnabled:NO];
    self.status.stringValue = [NSString stringWithFormat:
        @"stopped: %lu events, %lu offsets",
        (unsigned long)self.events.count, (unsigned long)self.offsets.count];
}

- (void)doSave:(id)sender {
    (void)sender;
    NSMutableString *j = [NSMutableString string];
    [j appendFormat:@"{\"app\": \"native\", \"t0\": %.6f, \"events\": [",
        rec_now()];
    for (NSUInteger i = 0; i < self.events.count; i++) {
        RecEntry *e = self.events[i];
        [j appendFormat:@"%@{\"t\": %.6f, \"sy\": %.6f, \"sx\": %.6f, "
         @"\"precise\": %d, \"phase\": %d, \"momentum\": %d}",
         i ? @", " : @"", e.t, e.sy, e.sx, e.precise, e.phase, e.momentum];
    }
    [j appendString:@"], \"offsets\": ["];
    for (NSUInteger i = 0; i < self.offsets.count; i++) {
        OffEntry *o = self.offsets[i];
        [j appendFormat:@"%@{\"t\": %.6f, \"y\": %.4f}", i ? @", " : @"",
         o.t, o.y];
    }
    [j appendString:@"]}"];
    NSError *err = nil;
    [j writeToFile:@REC_PATH atomically:YES encoding:NSUTF8StringEncoding
             error:&err];
    self.status.stringValue = err
        ? [NSString stringWithFormat:@"save FAILED: %@", err.localizedDescription]
        : [NSString stringWithFormat:@"saved → %s", REC_PATH];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a {
    (void)a; return YES;
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate *del = [AppDelegate new];
        app.delegate = del;
        [app run];
    }
    return 0;
}
