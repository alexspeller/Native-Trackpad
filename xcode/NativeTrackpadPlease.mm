#include <Core/CoreAll.h>
#include <Fusion/FusionAll.h>
#include <Cam/CamAll.h>

#include <Foundation/Foundation.h>
#include <Cocoa/Cocoa.h>

#import <objc/runtime.h>

#include <dlfcn.h>
#include <cmath>
#include <cstring>
#include <deque>
#include <utility>

using namespace adsk::core;
using namespace adsk::fusion;
using namespace adsk::cam;

adsk::core::Ptr<Application> app;
adsk::core::Ptr<UserInterface> ui;


/**
 * Helper function
 */
adsk::core::Ptr<Vector3D> getViewportCameraRightVector() {
    auto camera = app->activeViewport()->camera();

    auto right = camera->upVector();

    auto rotation = Matrix3D::create();
    auto axis = camera->eye()->vectorTo(camera->target());
    rotation->setToRotation(M_PI / 2, axis, Point3D::create(0, 0, 0));
    right->transformBy(rotation);

    return right;
}

/**
 * Helper function
 */
void panViewportCameraByVector(adsk::core::Ptr<Vector3D> vector) {
    auto camera = app->activeViewport()->camera();
    camera->isSmoothTransition(false);

    auto eye = camera->eye();
    eye->translateBy(vector);
    camera->eye(eye);

    auto target = camera->target();
    target->translateBy(vector);
    camera->target(target);

    app->activeViewport()->camera(camera);
    app->activeViewport()->refresh();
}

void orbit(double deltaX, double deltaY) {
    auto camera = app->activeViewport()->camera();
    camera->isSmoothTransition(false);

    deltaX = deltaX / 100 * -1;
    deltaY = deltaY / 100 * -1;

    auto up = camera->upVector();
    up->normalize();
    auto right = getViewportCameraRightVector();
    right->normalize();

    auto target = camera->target();
    auto eyeToTarget = target->vectorTo(camera->eye());

    auto origin = Point3D::create();

    auto rotation = adsk::core::Matrix3D::create();
    rotation->setToRotation(deltaX, up, origin);
    eyeToTarget->transformBy(rotation);

    rotation->setToRotation(deltaY, right, origin);
    eyeToTarget->transformBy(rotation);

    // TODO(ibash) handle isOk is false
    auto isOk = eyeToTarget->add(target->asVector());

    camera->eye(eyeToTarget->asPoint());

    app->activeViewport()->camera(camera);
    app->activeViewport()->refresh();
}

/**
 * Panning logic
 */
void pan(double deltaX, double deltaY) {
    auto camera = app->activeViewport()->camera();

    if (camera->cameraType() == OrthographicCameraType) {
        auto distance = sqrt(camera->viewExtents());

        deltaX *= distance / 250 * -1;
        deltaY *= distance / 250;
    }
    else {
        auto distance = camera->eye()->distanceTo(camera->target());

        deltaX *= distance / 2000 * -1;
        deltaY *= distance / 2000;
    }

    auto right = getViewportCameraRightVector();
    right->scaleBy(deltaX);

    auto up = app->activeViewport()->camera()->upVector();
    up->scaleBy(deltaY);

    right->add(up);

    panViewportCameraByVector(right);
}


/**
 * Zoom logic
 */
void zoom(double magnification) {
    // TODO zoom to mouse cursor

    auto camera = app->activeViewport()->camera();
    camera->isSmoothTransition(false);

    if (camera->cameraType() == OrthographicCameraType) {
        auto viewExtents = camera->viewExtents();
        camera->viewExtents(viewExtents + viewExtents * -magnification * 2);
    }
    else {
        auto eye = camera->eye();
        auto step = eye->vectorTo(camera->target());

        step->scaleBy(magnification * 0.9);

        eye->translateBy(step);
        camera->eye(eye);
    }

    app->activeViewport()->camera(camera);
    app->activeViewport()->refresh();
}

/**
 * Zoom to fit
 */
void zoomToFit() {
    ui->commandDefinitions()->itemById("FitCommand")->execute();
    app->activeViewport()->refresh();
}

/**
 * Pinch inertia. macOS sends momentum events after a flicked scroll but not after a pinch,
 * so we glide on ourselves: the zoom speed at release decays exponentially, like a scroll's.
 */
const NSTimeInterval kPinchSpeedWindow = 0.08;        // s of pinch before release that set the glide speed
const NSTimeInterval kPinchGlideTimeConstant = 0.25;  // s; the glide speed falls to 1/e in this time
const double kPinchGlideMinStartSpeed = 0.3;          // magnification/s; slower releases don't glide
const double kPinchGlideStopSpeed = 0.02;             // magnification/s
const NSTimeInterval kPinchGlideFrame = 1.0 / 60;

std::deque<std::pair<NSTimeInterval, double>> pinchSamples;  // (timestamp, magnification)
NSTimer* pinchGlideTimer = nil;
double pinchGlideSpeed = 0;  // magnification/s
NSTimeInterval pinchGlideLastTime = 0;

void stopPinchGlide() {
    [pinchGlideTimer invalidate];
    pinchGlideTimer = nil;
    pinchGlideSpeed = 0;
}

void recordPinchSample(NSEvent* event) {
    if (event.phase & NSEventPhaseBegan) {
        pinchSamples.clear();
    }
    pinchSamples.emplace_back(event.timestamp, event.magnification);
    while (pinchSamples.front().first < event.timestamp - kPinchSpeedWindow) {
        pinchSamples.pop_front();
    }
}

void pinchGlideStep() {
    // NSEvent timestamps and systemUptime are the same clock.
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    double decay = exp(-(now - pinchGlideLastTime) / kPinchGlideTimeConstant);
    // exactly how far the decaying speed travels since the last step, whatever the frame rate
    double step = pinchGlideSpeed * kPinchGlideTimeConstant * (1 - decay);
    pinchGlideSpeed *= decay;
    pinchGlideLastTime = now;
    try {
        if (!app || !app->activeViewport()) {
            stopPinchGlide();
            return;
        }
        zoom(step);
    } catch (...) {
        stopPinchGlide();
        return;
    }
    if (fabs(pinchGlideSpeed) < kPinchGlideStopSpeed) {
        stopPinchGlide();
    }
}

void startPinchGlide(NSTimeInterval endTime) {
    stopPinchGlide();
    double magnification = 0;
    for (const auto& sample : pinchSamples) {
        if (sample.first > endTime - kPinchSpeedWindow) {
            magnification += sample.second;
        }
    }
    pinchSamples.clear();
    // An Ended that turns up late (with the next pointer movement) glides only as fast as
    // it would be going by now, which is usually not at all.
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    double speed = magnification / kPinchSpeedWindow * exp(-fmax(0, now - endTime) / kPinchGlideTimeConstant);
    if (fabs(speed) < kPinchGlideMinStartSpeed) {
        return;
    }
    pinchGlideSpeed = speed;
    pinchGlideLastTime = now;
    pinchGlideTimer = [NSTimer timerWithTimeInterval:kPinchGlideFrame repeats:YES block:^(NSTimer* timer) {
        pinchGlideStep();
    }];
    // common modes, so it keeps going while a menu or a drag has the run loop
    [[NSRunLoop mainRunLoop] addTimer:pinchGlideTimer forMode:NSRunLoopCommonModes];
}

/**
 * Touching the trackpad, clicking or starting another gesture stops a glide.
 */
bool stopsPinchGlide(NSEvent* event) {
    switch (event.type) {
        case NSEventTypeLeftMouseDown:
        case NSEventTypeRightMouseDown:
        case NSEventTypeOtherMouseDown:
        case NSEventTypeSmartMagnify:
            return true;
        case NSEventTypeMouseMoved:
            return event.deltaX != 0 || event.deltaY != 0;
        case NSEventTypeMagnify:
            return (event.phase & NSEventPhaseBegan) != 0;
        case NSEventTypeScrollWheel:
            return (event.phase & (NSEventPhaseBegan | NSEventPhaseMayBegin)) != 0 ||
                   (event.phase == NSEventPhaseNone && event.momentumPhase == NSEventPhaseNone);
        default:
            return false;
    }
}

/**
 * Fusion's main window is titled "<document name> - Autodesk Fusion ..." these days,
 * so look for the name anywhere in the title (it used to be a prefix).
 */
bool isFusionWindow(NSEvent* event) {
    NSString* title = event.window.title;
    return title != nil && [title rangeOfString:@"Autodesk Fusion"].location != NSNotFound;
}

/**
 * Fusion's UI is Qt. The 3D view is a QTCanvas widget with an NSView of its own, while the
 * data panel, timeline and toolbars are drawn into other views of the same window.
 * Qt's exported QWidget::find() maps an NSView to its widget; the widget's class name comes
 * from its QMetaObject (metaObject() is the first virtual function of every QObject).
 */
typedef void* (*QWidgetFindFn)(unsigned long long);            // static QWidget* QWidget::find(WId)
typedef const char* (*QMetaObjectClassNameFn)(const void*);    // const char* QMetaObject::className() const
typedef const void* (*QObjectMetaObjectFn)(const void*);       // virtual const QMetaObject* QObject::metaObject() const

QWidgetFindFn qWidgetFind = nullptr;
QMetaObjectClassNameFn qMetaObjectClassName = nullptr;

bool isCanvasView(NSView* view) {
    if (view == nil) {
        return false;
    }
    void* widget = qWidgetFind((unsigned long long)(uintptr_t)(__bridge void*)view);
    if (widget == nullptr) {
        return false;
    }
    QObjectMetaObjectFn metaObject = (QObjectMetaObjectFn)(*(void* const* const*)widget)[0];
    const char* className = qMetaObjectClassName(metaObject(widget));
    return className != nullptr && strcmp(className, "QTCanvas") == 0;
}

/**
 * Is the pointer over the 3D view (and not the data panel, timeline, a toolbar, ...)?
 */
bool isOverCanvas(NSEvent* event) {
    NSWindow* window = event.window;
    if (window == nil) {
        return false;
    }
    if (qWidgetFind == nullptr || qMetaObjectClassName == nullptr) {
        // No Qt to ask, so treat the whole main window as the 3D view.
        return isFusionWindow(event);
    }
    // The frame view has no superview, so it takes the point in window coordinates.
    NSView* frameView = window.contentView.superview ?: window.contentView;
    return isCanvasView([frameView hitTest:event.locationInWindow]);
}

/**
 * Only the modifier keys we care about (ignores Caps Lock, Fn, device-dependent bits).
 */
NSEventModifierFlags modifiers(NSEvent* event) {
    return event.modifierFlags & (NSEventModifierFlagShift | NSEventModifierFlagControl |
                                  NSEventModifierFlagOption | NSEventModifierFlagCommand);
}

bool magnifyActive = false;
bool scrollActive = false;
NSTimeInterval lastScrollTime = 0;
// Where the current scroll / pinch started: the rest of it (and its momentum) goes the same way.
bool scrollOnCanvas = false;
bool magnifyOnCanvas = false;

/**
 * This function determines how we handle every event in app
 * Returns:
 * 0 = no change
 * 1 = discard event
 * 2 = pan
 * 3 = zoom
 * 4 = zoom to fit
 * 5 = orbit
 * 6 = pinch released, glide on
 */
int howWeShouldHandleEvent(NSEvent* event) {
    if (!app || !app->activeViewport()) {
        return 0;
    }

    NSEventModifierFlags mods = modifiers(event);
    bool onlyShiftOrNone = (mods & ~NSEventModifierFlagShift) == 0;

    if (event.type == NSEventTypeGesture) {
        return onlyShiftOrNone && isOverCanvas(event) ? 1 : 0;
    }
    if (event.type == NSEventTypeScrollWheel) {
        // Trackpad / Magic Mouse only; a notched mouse wheel keeps Fusion's own zoom.
        if (!onlyShiftOrNone || !event.hasPreciseScrollingDeltas) {
            return 0;
        }
        // Scrolls that start anywhere but the 3D view (data panel, timeline, ...) are Fusion's.
        bool starts = (event.phase & (NSEventPhaseBegan | NSEventPhaseMayBegin)) != 0;
        bool unphased = event.phase == NSEventPhaseNone && event.momentumPhase == NSEventPhaseNone;
        if (starts || unphased) {
            scrollOnCanvas = isOverCanvas(event);
        }
        if (!scrollOnCanvas) {
            return 0;
        }
        int move = (mods & NSEventModifierFlagShift) ? 5 : 2;

        // Some scroll events arrive late and out of order (e.g. a gesture's Ended, or
        // one of its Changed events, only turns up with the next pointer movement).
        // Acting on those makes the view jump after the gesture is over, so drop
        // anything older than the newest scroll event already seen.
        if (event.timestamp + 0.0005 < lastScrollTime) {
            return 1;
        }
        lastScrollTime = event.timestamp;

        if (event.momentumPhase != NSEventPhaseNone) {
            // Flick-to-glide keeps panning, but the fingers are off the trackpad now.
            if (event.momentumPhase & NSEventPhaseBegan) {
                scrollActive = false;
            }
            return move;
        }
        if (event.phase & (NSEventPhaseBegan | NSEventPhaseMayBegin)) {
            scrollActive = true;
            return move;
        }
        if (event.phase & (NSEventPhaseEnded | NSEventPhaseCancelled)) {
            scrollActive = false;
            return move;
        }
        if (event.phase == NSEventPhaseNone) {
            return move;
        }
        // Changed: only while the fingers are scrolling, strays are dropped.
        return scrollActive ? move : 1;
    }
    if (event.type == NSEventTypeMagnify) {
        if (mods != 0) {
            return 0;
        }
        if ((event.phase & NSEventPhaseBegan) || event.phase == NSEventPhaseNone) {
            magnifyOnCanvas = isOverCanvas(event);
        }
        if (!magnifyOnCanvas) {
            return 0;
        }
        // Stray Changed events can turn up after the pinch has Ended (with the next
        // pointer movement), so only zoom between Began and Ended/Cancelled.
        if (event.phase & NSEventPhaseBegan) {
            magnifyActive = true;
            return 3;
        }
        if (event.phase & (NSEventPhaseEnded | NSEventPhaseCancelled)) {
            bool glide = magnifyActive && (event.phase & NSEventPhaseEnded);
            magnifyActive = false;
            return glide ? 6 : 1;
        }
        if (event.phase == NSEventPhaseNone) {
            return 3;
        }
        return magnifyActive ? 3 : 1;
    }
    if (event.type == NSEventTypeSmartMagnify) {
        return mods == 0 && isOverCanvas(event) ? 4 : 0;
    }

    return 0;
}

/**
 * Returns the event to let Fusion handle it, or nil when we handled/discarded it.
 */
/**
 * The gestures we act on. Clicks and pointer moves are also watched, but only to stop a glide.
 */
const NSEventMask kGestureMask = NSEventMaskScrollWheel | NSEventMaskMagnify |
                                 NSEventMaskSmartMagnify | NSEventMaskGesture;
const NSEventMask kStopGlideMask = NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown |
                                   NSEventMaskOtherMouseDown | NSEventMaskMouseMoved;

NSEvent* handleEvent(NSEvent* event) {
    if (pinchGlideTimer != nil && stopsPinchGlide(event)) {
        stopPinchGlide();
    }
    if ((NSEventMaskFromType(event.type) & kGestureMask) == 0) {
        return event;
    }
    int result = 0;
    try {
        result = howWeShouldHandleEvent(event);
        if (result == 2) {
            pan(event.scrollingDeltaX, event.scrollingDeltaY);
        } else if (result == 3) {
            zoom(event.magnification);
            if (event.phase != NSEventPhaseNone) {
                recordPinchSample(event);
            }
        } else if (result == 6) {
            recordPinchSample(event);
            startPinchGlide(event.timestamp);
        } else if (result == 4) {
            zoomToFit();
        } else if (result == 5) {
            orbit(event.scrollingDeltaX, event.scrollingDeltaY);
        }
    } catch (...) {
        // never swallow an event because of an error on our side
        result = 0;
    }
    return result == 0 ? event : nil;
}

/**
 * We used to swizzle -[NSApplication sendEvent:], but Fusion now exchanges sendEvent:
 * with its own hook (NuBase10.dylib) and can swap it again later, which silently
 * undoes any other swizzle. A local event monitor is not affected by that.
 */
id eventMonitor = nil;

/**
 * Main entry here
 */
extern "C" XI_EXPORT bool run(const char* context) {
    app = Application::get();
    if (!app) { return false; }

    ui = app->userInterface();
    if (!ui) { return false; }

    qWidgetFind = (QWidgetFindFn)dlsym(RTLD_DEFAULT, "_ZN7QWidget4findEy");
    qMetaObjectClassName = (QMetaObjectClassNameFn)dlsym(RTLD_DEFAULT, "_ZNK11QMetaObject9classNameEv");

    if (eventMonitor == nil) {
        eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:kGestureMask | kStopGlideMask
                                                             handler:^NSEvent* (NSEvent* event) {
            return handleEvent(event);
        }];
    }

    return eventMonitor != nil;
}

/**
 * Stop overriding events
 */
extern "C" XI_EXPORT bool stop(const char* context) {
    stopPinchGlide();
    if (eventMonitor != nil) {
        [NSEvent removeMonitor:eventMonitor];
        eventMonitor = nil;
    }

    return true;
}
