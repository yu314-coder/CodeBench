import Foundation
import Metal
import MetalPerformanceShaders

/// Public C entry points for routing PyTorch matmuls onto the iPad
/// GPU. Reached from Python via `ctypes.CDLL(None)` once Swift names
/// them with `@_cdecl` — the main executable's symbol table is what
/// dlopen(NULL) hands back, and these public functions land in it.
///
/// One unified entry handles every case we patch on the Python side:
///   • 2-D (batch == 1) or batched (batch > 1, flattened by the caller)
///   • fp32 or fp16 (bf16 is cast to fp32 in Python before reaching us)
///   • optional transpose on either operand
///
/// Implementation uses public MetalPerformanceShaders only
/// (`MPSMatrixMultiplication` + the batched `MPSMatrixDescriptor`
/// initializer). No MPSGraph / private symbols, so App Store safe.

private enum MetalRT {
    /// One global device + queue. Creating these is ~100 ms each, so
    /// we hand them out once and reuse for every call.
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    static let queue:  MTLCommandQueue? = device?.makeCommandQueue()
}

/// 1 = Metal dispatch is usable, 0 = simulator / no device / etc.
@_cdecl("cb_metal_available")
public func cb_metal_available() -> Int32 {
    return MetalRT.device != nil ? 1 : 0
}

/// Forces the iOS linker to keep the `@_cdecl` symbols above and
/// export them in the binary's dynamic symbol table. Python reaches
/// them via `dlopen(NULL)` + `dlsym`, which the linker has no
/// visibility into — so without this any Release-build dead-strip
/// pass quietly removes them.
///
/// This is the same trick Flutter FFI uses (`DummyMethodToEnforce-
/// Bundling`): a direct call to every @_cdecl entry point. Taking
/// the address alone keeps the function body in `__text` but the
/// linker can still elide the export-table entry; a hard call site
/// it cannot.
///
/// `cb_metal_matmul_ex` returns -1 early when given nil pointers
/// (see the guard at the top of the function), so calling it with
/// zeros is safe and has no side effects.
public func _cbMetalBridgeKeepAlive() -> Int {
    let avail = Int(cb_metal_available())
    let rc = Int(cb_metal_matmul_ex(
        nil, 0, 0, 0,
        nil, 0, 0, 0,
        nil, 0, 0, 0
    ))
    return avail &+ rc
}

/// out = (A or A^T) @ (B or B^T)
/// Row-major, contiguous, matching batches (Python broadcasts before
/// calling). `dtype`: 0 = float32, 1 = float16.
/// Return: 0 ok, negative on failure (caller should fall back to CPU).
@_cdecl("cb_metal_matmul_ex")
public func cb_metal_matmul_ex(
    _ aPtr: UnsafeRawPointer?,
    _ aBatch: Int32, _ aRows: Int32, _ aCols: Int32,
    _ bPtr: UnsafeRawPointer?,
    _ bBatch: Int32, _ bRows: Int32, _ bCols: Int32,
    _ outPtr: UnsafeMutableRawPointer?,
    _ transposeA: Int32, _ transposeB: Int32,
    _ dtype: Int32
) -> Int32 {
    // Wrap the whole body in autoreleasepool. Python invokes us via
    // ctypes from a thread that has no run loop, so Cocoa/MPS objects
    // returned with autorelease (MTLBuffer, MPSMatrix*, MTLCommand-
    // Buffer, etc.) would otherwise pile up indefinitely — at several
    // MB per call, that's tens of GB after a normal training run.
    return autoreleasepool {
        guard let aPtr = aPtr, let bPtr = bPtr, let outPtr = outPtr else { return Int32(-1) }
        guard let device = MetalRT.device, let queue = MetalRT.queue else { return Int32(-2) }
        if aBatch != bBatch || aBatch < 1 { return Int32(-7) }

        let elemBytes: Int
        let mpsDT: MPSDataType
        switch dtype {
        case 0: elemBytes = MemoryLayout<Float>.size; mpsDT = .float32
        case 1: elemBytes = 2;                        mpsDT = .float16
        default: return Int32(-6)
        }

        let batch    = Int(aBatch)
        let aR       = Int(aRows), aC = Int(aCols)
        let bR       = Int(bRows), bC = Int(bCols)
        let transA   = transposeA != 0
        let transB   = transposeB != 0
        let resRows  = transA ? aC : aR
        let resCols  = transB ? bR : bC
        let interior = transA ? aR : aC
        let interiorB = transB ? bC : bR
        if interior != interiorB { return Int32(-9) }

        let aPerMat = aR * aC * elemBytes
        let bPerMat = bR * bC * elemBytes
        let oPerMat = resRows * resCols * elemBytes

        guard let aBuf = device.makeBuffer(bytes: aPtr, length: batch * aPerMat,
                                           options: [.storageModeShared]),
              let bBuf = device.makeBuffer(bytes: bPtr, length: batch * bPerMat,
                                           options: [.storageModeShared]),
              let oBuf = device.makeBuffer(length: batch * oPerMat,
                                           options: [.storageModeShared])
        else { return Int32(-3) }

        let aDesc: MPSMatrixDescriptor
        let bDesc: MPSMatrixDescriptor
        let oDesc: MPSMatrixDescriptor
        if batch == 1 {
            aDesc = MPSMatrixDescriptor(rows: aR, columns: aC,
                                        rowBytes: aC * elemBytes, dataType: mpsDT)
            bDesc = MPSMatrixDescriptor(rows: bR, columns: bC,
                                        rowBytes: bC * elemBytes, dataType: mpsDT)
            oDesc = MPSMatrixDescriptor(rows: resRows, columns: resCols,
                                        rowBytes: resCols * elemBytes, dataType: mpsDT)
        } else {
            aDesc = MPSMatrixDescriptor(rows: aR, columns: aC, matrices: batch,
                                        rowBytes: aC * elemBytes,
                                        matrixBytes: aPerMat, dataType: mpsDT)
            bDesc = MPSMatrixDescriptor(rows: bR, columns: bC, matrices: batch,
                                        rowBytes: bC * elemBytes,
                                        matrixBytes: bPerMat, dataType: mpsDT)
            oDesc = MPSMatrixDescriptor(rows: resRows, columns: resCols, matrices: batch,
                                        rowBytes: resCols * elemBytes,
                                        matrixBytes: oPerMat, dataType: mpsDT)
        }

        let aMat = MPSMatrix(buffer: aBuf, descriptor: aDesc)
        let bMat = MPSMatrix(buffer: bBuf, descriptor: bDesc)
        let oMat = MPSMatrix(buffer: oBuf, descriptor: oDesc)

        let kernel = MPSMatrixMultiplication(
            device: device,
            transposeLeft: transA, transposeRight: transB,
            resultRows: resRows, resultColumns: resCols,
            interiorColumns: interior,
            alpha: 1.0, beta: 0.0)
        if batch > 1 {
            kernel.batchStart = 0
            kernel.batchSize  = batch
        }

        guard let cmd = queue.makeCommandBuffer() else { return Int32(-4) }
        kernel.encode(commandBuffer: cmd,
                      leftMatrix:  aMat,
                      rightMatrix: bMat,
                      resultMatrix: oMat)
        cmd.commit()
        cmd.waitUntilCompleted()
        if cmd.error != nil { return Int32(-5) }

        memcpy(outPtr, oBuf.contents(), batch * oPerMat)
        return Int32(0)
    }
}
