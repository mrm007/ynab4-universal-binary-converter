#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <unistd.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "FlashRuntimeExtensions.h"

static NSString *fre_string_arg(FREObject object) {
    if (object == NULL) {
        return nil;
    }

    const uint8_t *value = NULL;
    uint32_t length = 0;
    if (FREGetObjectAsUTF8(object, &length, &value) != 0 || value == NULL) {
        return nil;
    }

    return [[NSString alloc] initWithBytes:value length:length encoding:NSUTF8StringEncoding];
}

static NSArray<NSString *> *fre_string_array_arg(FREObject object) {
    uint32_t length = 0;
    if (object == NULL || FREGetArrayLength(object, &length) != 0) {
        return @[];
    }

    NSMutableArray<NSString *> *values = [NSMutableArray arrayWithCapacity:length];
    for (uint32_t i = 0; i < length; i++) {
        FREObject element = NULL;
        if (FREGetArrayElementAt(object, i, &element) != 0) {
            continue;
        }

        NSString *value = fre_string_arg(element);
        if (value.length > 0) {
            [values addObject:value];
        }
    }

    return values;
}

static FREObject fre_bool(BOOL value) {
    FREObject object = NULL;
    FRENewObjectFromBool(value ? 1U : 0U, &object);
    return object;
}

static FREObject fre_string(NSString *value) {
    if (value == nil) {
        value = @"";
    }

    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    FREObject object = NULL;
    FRENewObjectFromUTF8((uint32_t)data.length, data.bytes, &object);
    return object;
}

static FREObject fre_string_array(NSArray<NSString *> *values) {
    FREObject array = NULL;
    FRENewObject((const uint8_t *)"Array", 0, NULL, &array, NULL);
    FRESetArrayLength(array, (uint32_t)values.count);

    for (uint32_t i = 0; i < values.count; i++) {
        FRESetArrayElementAt(array, i, fre_string(values[i]));
    }

    return array;
}

static BOOL is_writable_path(NSString *path) {
    if (path.length == 0) {
        return NO;
    }

    NSString *standardized = path.stringByStandardizingPath;
    const char *fsPath = standardized.fileSystemRepresentation;
    if (access(fsPath, W_OK) == 0) {
        return YES;
    }

    NSString *parent = standardized.stringByDeletingLastPathComponent;
    if (parent.length == 0 || [parent isEqualToString:standardized]) {
        return NO;
    }

    return access(parent.fileSystemRepresentation, W_OK) == 0;
}

static void dispatch_status(FREContext ctx, NSString *code, NSString *level) {
    const uint8_t *codeBytes = (const uint8_t *)code.UTF8String;
    const uint8_t *levelBytes = (const uint8_t *)(level ?: @"").UTF8String;
    FREDispatchStatusEventAsync(ctx, codeBytes, levelBytes);
}

static FREObject IsSandboxed(FREContext ctx, void *functionData, uint32_t argc, FREObject argv[]) {
    (void)ctx;
    (void)functionData;
    (void)argc;
    (void)argv;
    return fre_bool(NO);
}

static FREObject IsPathWriteable(FREContext ctx, void *functionData, uint32_t argc, FREObject argv[]) {
    (void)ctx;
    (void)functionData;
    NSString *path = argc > 0 ? fre_string_arg(argv[0]) : nil;
    return fre_bool(is_writable_path(path));
}

static FREObject ListFilenamesInDirectory(FREContext ctx, void *functionData, uint32_t argc, FREObject argv[]) {
    (void)ctx;
    (void)functionData;
    NSString *path = argc > 0 ? fre_string_arg(argv[0]) : nil;
    if (path.length == 0) {
        return fre_string_array(@[]);
    }

    NSError *error = nil;
    NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:&error];
    if (entries == nil || error != nil) {
        return fre_string_array(@[]);
    }

    return fre_string_array(entries);
}

static FREObject BrowseForFileOpen(FREContext ctx, void *functionData, uint32_t argc, FREObject argv[]) {
    (void)functionData;

    NSArray<NSString *> *allowedTypes = argc > 0 ? fre_string_array_arg(argv[0]) : @[];
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.canCreateDirectories = NO;
    if (allowedTypes.count > 0) {
        panel.allowedFileTypes = allowedTypes;
    }

    NSInteger result = [panel runModal];
    if (result == NSModalResponseOK && panel.URL != nil) {
        dispatch_status(ctx, @"FILE_SELECT", panel.URL.path);
        return fre_bool(YES);
    }

    dispatch_status(ctx, @"FILE_CANCEL", @"");
    return fre_bool(NO);
}

static FREObject ObtainWriteAccess(FREContext ctx, void *functionData, uint32_t argc, FREObject argv[]) {
    (void)functionData;

    NSString *requestedPath = argc > 0 ? fre_string_arg(argv[0]) : nil;
    if (is_writable_path(requestedPath)) {
        dispatch_status(ctx, @"FILE_SELECT", requestedPath ?: @"");
        return fre_bool(YES);
    }

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = YES;
    panel.prompt = @"Allow";
    panel.message = requestedPath.length > 0
        ? [NSString stringWithFormat:@"Select a folder that should be writable for YNAB.\nRequested path: %@", requestedPath]
        : @"Select a folder that should be writable for YNAB.";

    NSInteger result = [panel runModal];
    if (result == NSModalResponseOK && panel.URL != nil) {
        dispatch_status(ctx, @"FILE_SELECT", panel.URL.path);
        return fre_bool(YES);
    }

    dispatch_status(ctx, @"FILE_CANCEL", @"");
    return fre_bool(NO);
}

static FREObject RelaunchApp(FREContext ctx, void *functionData, uint32_t argc, FREObject argv[]) {
    (void)ctx;
    (void)functionData;
    (void)argc;
    (void)argv;

    NSString *bundlePath = [NSBundle mainBundle].bundlePath;
    if (bundlePath.length > 0) {
        [[NSWorkspace sharedWorkspace] openFile:bundlePath];
    }
    [NSApp terminate:nil];
    return fre_bool(YES);
}

static FREObject CheckAppStoreReceipt(FREContext ctx, void *functionData, uint32_t argc, FREObject argv[]) {
    (void)ctx;
    (void)functionData;
    (void)argc;
    (void)argv;

    NSString *receiptPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"Contents/_MASReceipt/receipt"];
    BOOL hasReceipt = receiptPath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:receiptPath];
    return fre_bool(hasReceipt);
}

// AIR replaces the green title-bar button's action with its own _playerZoom:, which YNAB receives as
// "maximize", so the button never enters full screen. AIR keeps AppKit's original action in the
// window's _cachedZoomAction ivar; putting it back restores the native behavior (click for full
// screen, Option-click to zoom).
static void restore_native_zoom_button(NSWindow *window) {
    Ivar cachedZoomAction = class_getInstanceVariable(object_getClass(window), "_cachedZoomAction");
    NSButton *zoomButton = [window standardWindowButton:NSWindowZoomButton];
    if (cachedZoomAction == NULL || zoomButton == nil || zoomButton.action != sel_registerName("_playerZoom:")) {
        return;
    }
    SEL nativeAction = *(SEL *)((uint8_t *)(__bridge void *)window + ivar_getOffset(cachedZoomAction));
    if (nativeAction != NULL) {
        zoomButton.action = nativeAction;
    }
}

static FREObject EnableFullScreenMode(FREContext ctx, void *functionData, uint32_t argc, FREObject argv[]) {
    (void)ctx;
    (void)functionData;
    (void)argc;
    (void)argv;

    // Match the original extension: make YNAB's main window full-screen capable. AIR 51 also keeps
    // its borderless splash window in NSApp.windows, so select titled, resizable windows only.
    BOOL enabled = NO;
    for (NSWindow *window in NSApp.windows) {
        NSWindowStyleMask styleMask = window.styleMask;
        if ((styleMask & NSWindowStyleMaskTitled) && (styleMask & NSWindowStyleMaskResizable)) {
            window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
            restore_native_zoom_button(window);
            enabled = YES;
        }
    }
    return fre_bool(enabled);
}

static BOOL (*original_menu_performKeyEquivalent)(id, SEL, NSEvent *);

// AIR offers every key press to the main menu, and AppKit treats the Globe modifier of its own
// "Enter Full Screen" (Globe-F) item as optional, so a plain F toggles full screen and never reaches
// YNAB. Every YNAB shortcut uses Command, so key presses without a shortcut modifier skip the menu.
static BOOL menu_performKeyEquivalent(id menu, SEL selector, NSEvent *event) {
    const NSEventModifierFlags shortcutModifiers = NSEventModifierFlagCommand | NSEventModifierFlagControl |
                                                   NSEventModifierFlagOption | NSEventModifierFlagFunction;
    if (event.type == NSEventTypeKeyDown && (event.modifierFlags & shortcutModifiers) == 0) {
        return NO;
    }
    return original_menu_performKeyEquivalent(menu, selector, event);
}

static void install_menu_key_filter(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method method = class_getInstanceMethod([NSMenu class], @selector(performKeyEquivalent:));
        original_menu_performKeyEquivalent =
            (BOOL (*)(id, SEL, NSEvent *))method_setImplementation(method, (IMP)menu_performKeyEquivalent);
    });
}

static void (*original_air_menu_insertItem)(id, SEL, NSMenuItem *, NSInteger);
static void (*appkit_menu_insertItem)(id, SEL, NSMenuItem *, NSInteger);
static Class air_menu_item_class;
static SEL platform_menu_item_selector;
static SEL set_platform_menu_item_selector;
static SEL dispatch_select_event_selector;
static SEL ivar_map_table_selector;
static char air_item_cleanup_key;

// AIR keeps each menu item's platform state in a table keyed by the item pointer, and its own item
// class removes the entry in -dealloc. This object does the same for an AppKit item when it is freed,
// so a new object at the same address never inherits a stale entry.
@interface YNABAIRMenuItemCleanup : NSObject
- (instancetype)initWithItem:(NSMenuItem *)item;
@end

@implementation YNABAIRMenuItemCleanup {
    const void *_item;
}

- (instancetype)initWithItem:(NSMenuItem *)item {
    if ((self = [super init])) {
        _item = (__bridge const void *)item;
    }
    return self;
}

- (void)dealloc {
    NSMapTable *table = ((NSMapTable * (*)(id, SEL))objc_msgSend)(air_menu_item_class, ivar_map_table_selector);
    NSMapRemove(table, _item);
}

@end

// AIR calls its item methods on every item it walks, so an item class that keeps its AppKit identity
// still needs them. AIR's implementations only touch the table above via [[self class] ivarMapTable].
static void add_air_item_methods(Class itemClass) {
    Class airMeta = object_getClass(air_menu_item_class);
    SEL instanceSelectors[] = {platform_menu_item_selector, set_platform_menu_item_selector, dispatch_select_event_selector};
    for (size_t i = 0; i < sizeof(instanceSelectors) / sizeof(instanceSelectors[0]); i++) {
        Method method = class_getInstanceMethod(air_menu_item_class, instanceSelectors[i]);
        class_addMethod(itemClass, instanceSelectors[i], method_getImplementation(method), method_getTypeEncoding(method));
    }
    Method tableMethod = class_getInstanceMethod(airMeta, ivar_map_table_selector);
    class_addMethod(object_getClass(itemClass), ivar_map_table_selector, method_getImplementation(tableMethod),
                    method_getTypeEncoding(tableMethod));
}

// AIR's NSMenu subclass rewrites the class of every item inserted into its menus to its own item
// class. AppKit recognizes the private NSMenuItem subclasses it adds to the Window menu (for example
// NSWindowSidecarMenuItem, "Move to <display>") by class, so after the rewrite it never removes the
// old ones and adds another copy each time the menu opens. Outside the menu bar itself, AIR's
// override does nothing else, so insert AppKit's item subclasses there with their class intact.
static void air_menu_insertItem(id menu, SEL selector, NSMenuItem *item, NSInteger index) {
    Class itemClass = [item class];
    if (menu != NSApp.mainMenu && itemClass != [NSMenuItem class] && ![itemClass isSubclassOfClass:air_menu_item_class]) {
        add_air_item_methods(itemClass);
        if (objc_getAssociatedObject(item, &air_item_cleanup_key) == nil) {
            objc_setAssociatedObject(item, &air_item_cleanup_key, [[YNABAIRMenuItemCleanup alloc] initWithItem:item],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        appkit_menu_insertItem(menu, selector, item, index);
        return;
    }
    original_air_menu_insertItem(menu, selector, item, index);
}

static void install_air_menu_insert_fix(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class airMenuClass = objc_getClass("AIR_PlayerContentMenu");
        air_menu_item_class = objc_getClass("AIR_PlayerContentMenuItem");
        platform_menu_item_selector = sel_registerName("platformMenuItem");
        set_platform_menu_item_selector = sel_registerName("setPlatformMenuItem:");
        dispatch_select_event_selector = sel_registerName("dispatchSelectEvent");
        ivar_map_table_selector = sel_registerName("ivarMapTable");
        SEL selector = @selector(insertItem:atIndex:);
        Method airInsert = airMenuClass ? class_getInstanceMethod(airMenuClass, selector) : NULL;
        Method appkitInsert = class_getInstanceMethod([NSMenu class], selector);
        // Only patch the AIR build this shim was written against.
        if (airInsert == NULL || air_menu_item_class == Nil || airInsert == appkitInsert ||
            !class_getInstanceMethod(air_menu_item_class, platform_menu_item_selector) ||
            !class_getInstanceMethod(air_menu_item_class, set_platform_menu_item_selector) ||
            !class_getInstanceMethod(air_menu_item_class, dispatch_select_event_selector) ||
            !class_getClassMethod(air_menu_item_class, ivar_map_table_selector)) {
            return;
        }
        appkit_menu_insertItem = (void (*)(id, SEL, NSMenuItem *, NSInteger))method_getImplementation(appkitInsert);
        original_air_menu_insertItem =
            (void (*)(id, SEL, NSMenuItem *, NSInteger))method_setImplementation(airInsert, (IMP)air_menu_insertItem);
    });
}

static void MacUtilsContextFinalizer(FREContext ctx) {
    (void)ctx;
}

static void MacUtilsContextInitializer(void *extData, const uint8_t *ctxType, FREContext ctx,
                                       uint32_t *numFunctionsToSet, const FRENamedFunction **functionsToSet) {
    (void)extData;
    (void)ctxType;
    (void)ctx;

    static FRENamedFunction functions[] = {
        {(const uint8_t *)"BrowseForFileOpen", NULL, &BrowseForFileOpen},
        {(const uint8_t *)"CheckAppStoreReceipt", NULL, &CheckAppStoreReceipt},
        {(const uint8_t *)"EnableFullScreenMode", NULL, &EnableFullScreenMode},
        {(const uint8_t *)"IsPathWriteable", NULL, &IsPathWriteable},
        {(const uint8_t *)"IsSandboxed", NULL, &IsSandboxed},
        {(const uint8_t *)"ListFilenamesInDirectory", NULL, &ListFilenamesInDirectory},
        {(const uint8_t *)"ObtainWriteAccess", NULL, &ObtainWriteAccess},
        {(const uint8_t *)"RelaunchApp", NULL, &RelaunchApp},
    };

    *numFunctionsToSet = (uint32_t)(sizeof(functions) / sizeof(functions[0]));
    *functionsToSet = functions;
}

void NativeExtensionsInitializer(void **extDataToSet, FREContextInitializer *ctxInitializerToSet,
                                 FREContextFinalizer *ctxFinalizerToSet) {
    *extDataToSet = NULL;
    *ctxInitializerToSet = &MacUtilsContextInitializer;
    *ctxFinalizerToSet = &MacUtilsContextFinalizer;
    install_menu_key_filter();
    install_air_menu_insert_fix();
}

void NativeExtensionsFinalizer(void *extData) {
    (void)extData;
}
