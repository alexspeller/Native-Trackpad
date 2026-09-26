#include <Core/CoreAll.h>
#include <Fusion/FusionAll.h>
#include <Cam/CamAll.h>

#include <Foundation/Foundation.h>
#include <Cocoa/Cocoa.h>

#import <objc/runtime.h>

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
 * Fusion's main window is titled "<document name> - Autodesk Fusion ..." these days,
 * so look for the name anywhere in the title (it used to be a prefix).
 */
bool isFusionWindow(NSEvent* event) {
    NSString* title = event.window.title;
    return title != nil && [title rangeOfString:@"Autodesk Fusion"].location != NSNotFound;
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

/**
 * This function determines how we handle every event in app
 * Returns:
 * 0 = no change
 * 1 = discard event
 * 2 = pan
 * 3 = zoom
 * 4 = zoom to fit
 * 5 = orbit
 */
int howWeShouldHandleEvent(NSEvent* event) {
    // TODO handle only events to QTCanvas

    if (!app || !app->activeViewport() || !isFusionWindow(event)) {
        return 0;
    }

    NSEventModifierFlags mods = modifiers(event);
    bool onlyShiftOrNone = (mods & ~NSEventModifierFlagShift) == 0;

    if (event.type == NSEventTypeGesture) {
        return onlyShiftOrNone ? 1 : 0;
    }
    if (event.type == NSEventTypeScrollWheel) {
        // Trackpad / Magic Mouse only; a notched mouse wheel keeps Fusion's own zoom.
        if (!onlyShiftOrNone || !event.hasPreciseScrollingDeltas) {
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
        // Stray Changed events can turn up after the pinch has Ended (with the next
        // pointer movement), so only zoom between Began and Ended/Cancelled.
        if (event.phase & NSEventPhaseBegan) {
            magnifyActive = true;
            return 3;
        }
        if (event.phase & (NSEventPhaseEnded | NSEventPhaseCancelled)) {
            magnifyActive = false;
            return 1;
        }
        if (event.phase == NSEventPhaseNone) {
            return 3;
        }
        return magnifyActive ? 3 : 1;
    }
    if (event.type == NSEventTypeSmartMagnify) {
        return mods == 0 ? 4 : 0;
    }

    return 0;
}

/**
 * Returns the event to let Fusion handle it, or nil when we handled/discarded it.
 */
NSEvent* handleEvent(NSEvent* event) {
    int result = 0;
    try {
        result = howWeShouldHandleEvent(event);
        if (result == 2) {
            pan(event.scrollingDeltaX, event.scrollingDeltaY);
        } else if (result == 3) {
            zoom(event.magnification);
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

    if (eventMonitor == nil) {
        NSEventMask mask = NSEventMaskScrollWheel | NSEventMaskMagnify |
                           NSEventMaskSmartMagnify | NSEventMaskGesture;
        eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask
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
    if (eventMonitor != nil) {
        [NSEvent removeMonitor:eventMonitor];
        eventMonitor = nil;
    }

    return true;
}
