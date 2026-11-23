import Limb
import Synchronization

private final class StepState: Sendable {
    let text = Mutex("idle")
    let completion = Mutex<AsyncStream<Void>.Continuation?>(nil)
}

func registerSteps(on server: Server) throws {
    let state = StepState()
    let mimeType = "text/plain"
    try server.register(resource: .init(
        uri: "limb-fixture://state/steps", name: "steps", mimeType: mimeType
    )) { request, _ in
        [.text(uri: request.uri, mimeType: mimeType, text: state.text.withLock { $0 })]
    }
    try server.register(tool: .init(
        name: "run_steps", description: "Reports a step and optionally waits for cancellation.",
        inputSchema: [
            "type": "object", "properties": ["mode": ["type": "string", "enum": ["complete", "continue", "cancel"]]],
            "required": ["mode"],
        ]
    )) { arguments, context in
        let mode: String = try arguments.required("mode")
        if mode == "continue" {
            guard let continuation = state.completion.withLock({ $0 }) else {
                throw ToolError("No step is waiting to complete.")
            }
            continuation.finish()
            return .text("released")
        }
        if mode == "complete" {
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            try state.completion.withLock {
                guard $0 == nil else { throw ToolError("A step is already waiting to complete.") }
                $0 = continuation
            }
            defer { state.completion.withLock { $0 = nil } }
            // The client releases the handler after it receives progress.
            context.progress(1, total: 1, message: "completed")
            for await _ in stream {}
            try Task.checkCancellation()
            state.text.withLock { $0 = "completed" }
            return .text("completed")
        }

        state.text.withLock { $0 = "running" }
        context.progress(1, total: 2, message: "started")
        do {
            try await Task.sleep(for: .seconds(10))
        } catch is CancellationError {
            state.text.withLock { $0 = "cancelled" }
            throw CancellationError()
        }
        state.text.withLock { $0 = "finished without cancellation" }
        return .text("finished without cancellation")
    }
}
