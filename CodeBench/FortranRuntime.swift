import Foundation

/// Swift wrapper for the CodeBench Fortran interpreter (ofort).
/// Executes Fortran code interpreted on-device — no JIT, no compilation, App Store safe.
final class FortranRuntime {
    static let shared = FortranRuntime()

    struct ExecutionResult {
        let output: String
        let error: String?
        let success: Bool
    }

    /// ofort is a tree-walking interpreter with very large stack frames: its
    /// AST nodes and parser locals (OfortNode/OfortToken) are ~13 KB each and
    /// are used as recursive-descent locals, so even a trivial program needs
    /// 256–512 KB of stack. On iOS the Fortran run happens deep inside the
    /// Python run-chain, so the ~512 KB default worker-thread stack has far
    /// less than that left → EXC_BAD_ACCESS (code=2) at a stack address,
    /// instantly. So we always run the interpreter on a dedicated thread with
    /// a fresh, generous stack — independent of how deep the caller is.
    /// (Stack is virtual / lazily committed, so a large reservation is cheap.)
    private static let interpreterStackSize = 64 * 1024 * 1024   // 64 MB

    /// Holds the result across the worker-thread boundary. Access is
    /// serialized by the semaphore (write-then-signal, wait-then-read), so
    /// it's safe to mark Sendable.
    private final class ResultBox: @unchecked Sendable {
        var result = ExecutionResult(
            output: "", error: "Fortran interpreter thread did not run", success: false)
    }

    private let queue = DispatchQueue(label: "ai.codebench.fortran-runtime", qos: .userInitiated)

    private init() {}

    /// Execute Fortran source synchronously. Runs the interpreter on a
    /// large-stack thread and blocks the caller until it finishes.
    func execute(_ source: String) -> ExecutionResult {
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        let worker = Thread {
            box.result = FortranRuntime.runInterpreter(source)
            sem.signal()
        }
        worker.stackSize = FortranRuntime.interpreterStackSize
        worker.qualityOfService = .userInitiated
        worker.name = "ai.codebench.fortran-interp"
        worker.start()
        sem.wait()
        return box.result
    }

    /// The actual ofort call sequence. MUST run on a large-stack thread
    /// (see `interpreterStackSize`) — never call this directly.
    private static func runInterpreter(_ source: String) -> ExecutionResult {
        guard let interp = ofort_create() else {
            return ExecutionResult(output: "", error: "Failed to create Fortran interpreter", success: false)
        }
        defer { ofort_destroy(interp) }

        let result = ofort_execute(interp, source)
        let output = String(cString: ofort_get_output(interp))
        let error = String(cString: ofort_get_error(interp))

        if result != 0 {
            return ExecutionResult(
                output: output,
                error: error.isEmpty ? "Fortran execution failed" : error,
                success: false
            )
        }
        return ExecutionResult(output: output, error: nil, success: true)
    }

    /// Execute Fortran source on a background thread, returning via completion handler.
    func executeAsync(_ source: String, completion: @escaping (ExecutionResult) -> Void) {
        queue.async {
            let result = self.execute(source)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}
