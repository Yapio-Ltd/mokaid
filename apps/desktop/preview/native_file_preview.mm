#include <mokaid/preview/native_file_preview.hpp>

#include <QFileInfo>

#import <AppKit/AppKit.h>
#import <Quartz/Quartz.h>

@interface MokaidNativePreviewItem : NSObject <QLPreviewItem>
@property(nonatomic, copy) NSURL* fileURL;
@property(nonatomic, copy) NSString* displayTitle;
@end

@implementation MokaidNativePreviewItem
- (NSURL*)previewItemURL { return self.fileURL; }
- (NSString*)previewItemTitle { return self.displayTitle; }
@end

// Quick Look discovers its controller through the AppKit responder chain.
// Inserting a responder preserves Qt's application delegate and window handlers.
@interface MokaidNativePreviewController : NSResponder <QLPreviewPanelDataSource>
@property(nonatomic, strong) MokaidNativePreviewItem* item;
@property(nonatomic, weak) NSResponder* anchor;
- (void)attach;
- (void)stop;
@end

static __weak MokaidNativePreviewController* activePreviewController;

@implementation MokaidNativePreviewController

- (void)attach {
    self.anchor = NSApp.mainWindow;
    if (!self.anchor) self.anchor = NSApp.keyWindow;
    if (!self.anchor) self.anchor = NSApp;
    if (self.anchor.nextResponder != self) {
        self.nextResponder = self.anchor.nextResponder;
        self.anchor.nextResponder = self;
    }
}

- (BOOL)acceptsPreviewPanelControl:(QLPreviewPanel*)panel {
    (void)panel;
    return self.item != nil;
}

- (void)beginPreviewPanelControl:(QLPreviewPanel*)panel {
    panel.dataSource = self;
}

- (void)endPreviewPanelControl:(QLPreviewPanel*)panel {
    if (panel.dataSource == self) {
        panel.dataSource = nil;
    }
}

- (NSInteger)numberOfPreviewItemsInPreviewPanel:(QLPreviewPanel*)panel {
    (void)panel;
    return self.item ? 1 : 0;
}

- (id<QLPreviewItem>)previewPanel:(QLPreviewPanel*)panel previewItemAtIndex:(NSInteger)index {
    (void)panel;
    return index == 0 ? self.item : nil;
}

- (void)stop {
    QLPreviewPanel* panel = [QLPreviewPanel sharedPreviewPanelExists]
        ? [QLPreviewPanel sharedPreviewPanel] : nil;
    const BOOL controlsPanel = panel && panel.currentController == self;

    // Empty the data source before the owner can evict the temporary source.
    self.item = nil;
    if (controlsPanel) {
        if (panel.inFullScreenMode) {
            [panel exitFullScreenModeWithOptions:nil];
        }
        [panel reloadData];
        [panel orderOut:nil];
        [panel close];
        [panel setIsVisible:NO];
    }

    // Another responder might have been inserted since attach; remove only us.
    NSResponder* previous = self.anchor;
    for (NSUInteger depth = 0; previous && depth < 128; ++depth) {
        if (previous.nextResponder == self) {
            previous.nextResponder = self.nextResponder;
            break;
        }
        previous = previous.nextResponder;
    }
    self.anchor = nil;
    self.nextResponder = nil;
    if (controlsPanel) {
        [panel updateController];
    }
    if (activePreviewController == self) {
        activePreviewController = nil;
    }
}

@end

namespace mokaid::desktop {

struct NativeFilePreview::Private {
    MokaidNativePreviewController* __strong controller = nil;
};

NativeFilePreview::NativeFilePreview() : d_(std::make_unique<Private>()) {}
NativeFilePreview::~NativeFilePreview() { clear(); }

bool NativeFilePreview::available() noexcept {
    return [NSThread isMainThread] && NSApp != nil;
}

bool NativeFilePreview::open(const QUrl& localFile, const QString& title) {
    if (!available() || !localFile.isValid() || !localFile.isLocalFile()
        || !localFile.host().isEmpty() || !localFile.userInfo().isEmpty()
        || localFile.hasQuery() || localFile.hasFragment()) {
        return false;
    }

    const auto path = localFile.toLocalFile();
    const QFileInfo info(path);
    // Symlinks are unnecessary for our owned temporary files. Reject them along
    // with directories, sockets, devices and unreadable or missing files.
    if (path.contains(QChar::Null) || !info.isAbsolute() || info.isSymLink()
        || !info.exists() || !info.isFile() || !info.isReadable()) {
        return false;
    }
    const auto canonicalPath = info.canonicalFilePath();
    if (canonicalPath.isEmpty()) {
        return false;
    }

    clear();
    // QLPreviewPanel is process-wide; release the previous helper's ownership.
    [activePreviewController stop];

    const auto pathBytes = canonicalPath.toUtf8();
    NSString* nativePath = [[NSString alloc] initWithBytes:pathBytes.constData()
        length:static_cast<NSUInteger>(pathBytes.size()) encoding:NSUTF8StringEncoding];
    const auto titleBytes = (title.isEmpty() ? info.fileName() : title).toUtf8();
    NSString* nativeTitle = [[NSString alloc] initWithBytes:titleBytes.constData()
        length:static_cast<NSUInteger>(titleBytes.size()) encoding:NSUTF8StringEncoding];
    if (!nativePath || !nativeTitle) {
        return false;
    }

    auto* item = [[MokaidNativePreviewItem alloc] init];
    item.fileURL = [NSURL fileURLWithPath:nativePath isDirectory:NO];
    item.displayTitle = nativeTitle;
    d_->controller = [[MokaidNativePreviewController alloc] init];
    d_->controller.item = item;
    activePreviewController = d_->controller;
    [d_->controller attach];

    QLPreviewPanel* panel = [QLPreviewPanel sharedPreviewPanel];
    const BOOL wasVisible = panel.isVisible;
    [panel makeKeyAndOrderFront:nil];
    [panel updateController];
    if (panel.currentController != d_->controller) {
        if (!wasVisible && !panel.currentController) [panel close];
        clear();
        return false;
    }
    [panel reloadData];
    panel.currentPreviewItemIndex = 0;
    return true;
}

void NativeFilePreview::clear() {
    if (!d_->controller) {
        return;
    }
    auto* controller = d_->controller;
    if ([NSThread isMainThread]) {
        [controller stop];
    } else {
        // Destruction must detach AppKit's non-owning dataSource synchronously.
        dispatch_sync(dispatch_get_main_queue(), ^{ [controller stop]; });
    }
    d_->controller = nil;
}

} // namespace mokaid::desktop
