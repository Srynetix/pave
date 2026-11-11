import Foundation

/// A dedicated thread with its own CFRunLoop, one per tracked application.
///
/// Every Accessibility call to an app is a blocking IPC. Running them on a thread
/// per app means a hung app (or one stopped with `kill -STOP`) only blocks its own
/// thread: the rest of Pavé keeps working (M0 / H2). AXObserver notifications
/// are delivered on the same run loop, so all of an app's AX state is confined
/// to this thread.
final class AppThread: Thread, @unchecked Sendable {
    private var runLoop: CFRunLoop!
    private let ready = DispatchSemaphore(value: 0)

    /// Starts the thread and returns once its run loop accepts work.
    func startAndWait() {
        start()
        ready.wait()
    }

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // A run loop with no source returns immediately: keep it alive with a far-future timer.
        let keepAlive = CFRunLoopTimerCreateWithHandler(
            nil, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0
        ) { _ in }
        CFRunLoopAddTimer(runLoop, keepAlive, .defaultMode)
        ready.signal()
        while !isCancelled {
            CFRunLoopRunInMode(.defaultMode, 1e9, false)
        }
    }

    /// Runs `block` on this thread, asynchronously.
    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    /// Runs `block` on this thread after `delay` seconds.
    func after(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        let timer = CFRunLoopTimerCreateWithHandler(
            nil, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0
        ) { _ in block() }
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
        CFRunLoopWakeUp(runLoop)
    }

    /// Stops the run loop; the thread exits once its current work is done.
    func stop() {
        cancel()
        perform { CFRunLoopStop(CFRunLoopGetCurrent()) }
    }
}
