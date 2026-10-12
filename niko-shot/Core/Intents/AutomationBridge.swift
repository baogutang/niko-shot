// Keeps all automation entry points on the resident application's main-actor execution path.
import Foundation

/// Validates requests before dispatching them to the resident application's capture coordinator.
@MainActor
public final class AutomationBridge {
    /// The single bridge used by App Intents and the resident IPC server.
    public static let shared = AutomationBridge()
    /// The resident handler; absent during startup and after termination begins.
    public var handler: (@MainActor @Sendable (AutomationCommand) async throws -> AutomationResponse)? {
        didSet { availabilityDidChange?() }
    }
    var availabilityDidChange: (@MainActor @Sendable () -> Void)?

    /// Creates an isolated bridge, useful for deterministic automation tests.
    public init() {}

    /// Executes one validated command; it never retries or selects another execution path.
    public func execute(_ command: AutomationCommand) async throws -> AutomationResponse {
        let command = try command.validated()
        try Task.checkCancellation()
        guard let handler else { throw AutomationError.unavailable }
        let response = try await handler(command)
        try Task.checkCancellation()
        return response
    }
}
