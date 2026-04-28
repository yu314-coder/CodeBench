import Foundation

/// Swift wrapper for the CodeBench C++ Interpreter.
/// Executes C++ code interpreted on-device — no JIT, no compilation, App Store safe.
final class CppRuntime {
    static let shared = CppRuntime()

    struct ExecutionResult {
        let output: String
        let error: String?
        let success: Bool
    }

    private let queue = DispatchQueue(label: "ai.codebench.cpp-runtime", qos: .userInitiated)

    private init() {}

    func execute(_ source: String) -> ExecutionResult {
        guard let interp = ocpp_create() else {
            return ExecutionResult(output: "", error: "Failed to create C++ interpreter", success: false)
        }
        defer { ocpp_destroy(interp) }

        let result = ocpp_execute(interp, source)
        let output = String(cString: ocpp_get_output(interp))
        let error = String(cString: ocpp_get_error(interp))

        if result != 0 {
            return ExecutionResult(
                output: output,
                error: error.isEmpty ? "C++ execution failed" : error,
                success: false
            )
        }

        return ExecutionResult(output: output, error: nil, success: true)
    }

    func executeAsync(_ source: String, completion: @escaping (ExecutionResult) -> Void) {
        queue.async {
            let result = self.execute(source)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}
