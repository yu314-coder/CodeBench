import Foundation

/// Swift wrapper for the CodeBench Fortran Interpreter.
/// Executes Fortran code interpreted on-device — no JIT, no compilation, App Store safe.
final class FortranRuntime {
    static let shared = FortranRuntime()

    struct ExecutionResult {
        let output: String
        let error: String?
        let success: Bool
    }

    private let queue = DispatchQueue(label: "ai.codebench.fortran-runtime", qos: .userInitiated)

    private init() {}

    /// Execute Fortran source code synchronously on the caller's thread.
    func execute(_ source: String) -> ExecutionResult {
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

    /// Execute Fortran source code on a background thread, returning via completion handler.
    func executeAsync(_ source: String, completion: @escaping (ExecutionResult) -> Void) {
        queue.async {
            let result = self.execute(source)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}
