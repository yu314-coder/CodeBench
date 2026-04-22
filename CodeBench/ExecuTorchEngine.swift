import Foundation
import ExecuTorch

/// On-device PyTorch inference via ExecuTorch.
///
/// ExecuTorch is Meta's current on-device PyTorch runtime (replaces the
/// deprecated libtorch-iOS Mobile). Users export a PyTorch model to `.pte`
/// ahead of time with `torch.export() → executorch.compile()`, then this
/// engine loads the `.pte` and runs `forward()` on CPU (XNNPACK), Neural
/// Engine (CoreML) or GPU (MPS) backends.
///
/// Bridges to Python via file-based IPC so users can write:
///
///     import offlinai_torch
///     m = offlinai_torch.Module("resnet18.pte")
///     out = m.forward(np.random.randn(1, 3, 224, 224).astype("float32"))
///
/// Protocol:
///   Python writes  req_<id>.json   into  $TMPDIR/executorch_signals/
///   Swift          reads it, runs the model, writes resp_<id>.json.
/// Mirrors the offlinai_intellisense pattern.
final class ExecuTorchEngine {

    static let shared = ExecuTorchEngine()

    /// Cache of loaded Modules so repeated forwards don't re-parse the .pte.
    private var modules: [String: Module] = [:]
    private let lock = NSLock()

    private let signalDir: URL
    private let outDir: URL
    private var watchQueue = DispatchQueue(label: "offlinai.executorch.watch", qos: .userInitiated)
    private var isRunning = false

    private init() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        self.signalDir = tmp.appendingPathComponent("executorch_signals", isDirectory: true)
        self.outDir    = signalDir.appendingPathComponent("outputs", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    // MARK: - Lifecycle

    /// Start the watch loop. Called once from `GameViewController.viewDidLoad`.
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !isRunning else { return }
        isRunning = true
        watchQueue.async { [weak self] in self?.watchLoop() }
        print("[ExecuTorch] Engine started, watching \(signalDir.path)")
    }

    private func watchLoop() {
        let fm = FileManager.default
        let heartbeat = signalDir.appendingPathComponent(".engine_alive")
        while isRunning {
            // Heartbeat so `offlinai_torch.is_available()` can detect us.
            try? Data().write(to: heartbeat, options: .atomic)

            guard let entries = try? fm.contentsOfDirectory(at: signalDir, includingPropertiesForKeys: nil) else {
                Thread.sleep(forTimeInterval: 0.1); continue
            }
            let requests = entries.filter {
                $0.lastPathComponent.hasPrefix("req_") && $0.pathExtension == "json"
            }
            for reqURL in requests {
                autoreleasepool { handleRequest(at: reqURL) }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // MARK: - Request handling

    private func handleRequest(at url: URL) {
        // Move the request out of the inbox atomically so another iteration
        // doesn't pick it up. If the move fails, another worker claimed it.
        let claimed = url.deletingPathExtension().appendingPathExtension("claimed.json")
        do { try FileManager.default.moveItem(at: url, to: claimed) }
        catch { return }
        defer { try? FileManager.default.removeItem(at: claimed) }

        guard let data = try? Data(contentsOf: claimed),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id   = obj["id"] as? String else { return }

        let response: [String: Any]
        do {
            response = try processRequest(obj)
        } catch {
            response = ["ok": false, "error": "\(error)"]
        }

        let respURL = signalDir.appendingPathComponent("resp_\(id).json")
        if let body = try? JSONSerialization.data(withJSONObject: response) {
            try? body.write(to: respURL, options: .atomic)
        }
    }

    private func processRequest(_ req: [String: Any]) throws -> [String: Any] {
        guard let kind = req["kind"] as? String else {
            return ["ok": false, "error": "missing kind"]
        }
        switch kind {
        case "load":     return try handleLoad(req)
        case "forward":  return try handleForward(req)
        case "metadata": return try handleMetadata(req)
        default:         return ["ok": false, "error": "unknown kind: \(kind)"]
        }
    }

    private func handleLoad(_ req: [String: Any]) throws -> [String: Any] {
        guard let path = req["path"] as? String else { return ["ok": false, "error": "missing path"] }
        let module = try loadModule(path: path)
        let methods = try module.methodNames().sorted()
        return ["ok": true, "methods": methods]
    }

    private func handleMetadata(_ req: [String: Any]) throws -> [String: Any] {
        guard let path = req["path"] as? String else { return ["ok": false, "error": "missing path"] }
        let method = (req["method"] as? String) ?? "forward"
        let module = try loadModule(path: path)
        let meta = try module.methodMetadata(method)
        let inputs  = meta.inputTensorMetadata.map  { (k, v) in ["index": k, "shape": v.shape, "dtype": dtypeName(v.dataType)] as [String: Any] }
        let outputs = meta.outputTensorMetadata.map { (k, v) in ["index": k, "shape": v.shape, "dtype": dtypeName(v.dataType)] as [String: Any] }
        return ["ok": true, "inputs": inputs, "outputs": outputs]
    }

    private func handleForward(_ req: [String: Any]) throws -> [String: Any] {
        guard let path       = req["path"]        as? String,
              let tensorFile = req["input_file"]  as? String,
              let shape      = req["shape"]       as? [Int],
              let dtypeStr   = req["dtype"]       as? String else {
            return ["ok": false, "error": "missing path/input_file/shape/dtype"]
        }
        let method = (req["method"] as? String) ?? "forward"
        let reqId  = (req["id"]     as? String) ?? UUID().uuidString
        let module = try loadModule(path: path)

        // Read input bytes into Data; build an AnyTensor over them.
        let inputData = try Data(contentsOf: URL(fileURLWithPath: tensorFile))
        let dtype = try parseDType(dtypeStr)
        let input = AnyTensor(data: inputData, shape: shape, dataType: dtype)

        // Run forward.
        let outputs: [Value] = try module.execute(method, [input])

        // Serialize every output tensor to a binary file.
        var outputMetas: [[String: Any]] = []
        for (i, v) in outputs.enumerated() {
            guard v.isTensor, let t = v.anyTensor else {
                outputMetas.append(["error": "non-tensor output at \(i)"])
                continue
            }
            let outFile = outDir.appendingPathComponent("\(reqId)_out\(i).bin")
            // Copy bytes out of the tensor via the closure API, then write.
            var blob = Data()
            t.bytes { ptr, count, dt in
                blob = Data(bytes: ptr, count: count * Self.sizeOf(dt))
            }
            try blob.write(to: outFile, options: .atomic)
            outputMetas.append([
                "index": i,
                "file":  outFile.path,
                "shape": t.shape,
                "dtype": dtypeName(t.dataType),
            ])
        }
        return ["ok": true, "outputs": outputMetas]
    }

    // MARK: - Helpers

    private func loadModule(path: String) throws -> Module {
        lock.lock(); defer { lock.unlock() }
        if let cached = modules[path] { return cached }
        let module = Module(filePath: path)
        try module.load()
        modules[path] = module
        return module
    }

    private func parseDType(_ s: String) throws -> DataType {
        switch s {
        case "float32", "f32": return .float
        case "float64", "f64", "double": return .double
        case "int32", "i32":   return .int
        case "int64", "i64":   return .long
        case "int16", "i16":   return .short
        case "int8",  "i8":    return .char
        case "uint8":          return .byte
        case "bool":           return .bool
        default:
            throw NSError(domain: "ExecuTorchEngine", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported dtype: \(s)"])
        }
    }

    private func dtypeName(_ dt: DataType) -> String {
        switch dt {
        case .float:  return "float32"
        case .double: return "float64"
        case .int:    return "int32"
        case .long:   return "int64"
        case .short:  return "int16"
        case .char:   return "int8"
        case .byte:   return "uint8"
        case .bool:   return "bool"
        default:      return "unknown"
        }
    }

    private static func sizeOf(_ dt: DataType) -> Int {
        switch dt {
        case .float, .int:    return 4
        case .double, .long:  return 8
        case .short:          return 2
        case .char, .byte, .bool: return 1
        default:              return 1
        }
    }
}
