import Foundation

extension Process {
    /// Starts the process and returns a function that blocks until it exits.
    ///
    /// Use this instead of `waitUntilExit()`, which spins the current run
    /// loop while it waits. On the main thread that lets SwiftUI run a view
    /// update in the middle of the call, and if that update re-enters the
    /// code that started the process (a lazily initialised `static let`,
    /// say) the app traps. This waits on a semaphore that the termination
    /// handler signals from a background thread, so nothing else runs.
    ///
    /// Read the pipes to the end before calling the returned function, so a
    /// chatty process can't fill a pipe and stall.
    func launchForBlockingWait() throws -> () -> Void {
        let exited = DispatchSemaphore(value: 0)
        terminationHandler = { _ in exited.signal() }
        try run()
        return { exited.wait() }
    }
}
