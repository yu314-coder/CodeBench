//
//  CodeBench-Bridging-Header.h
//

#ifndef CodeBench_Bridging_Header_h
#define CodeBench_Bridging_Header_h

// UIKit was previously pulled in transitively by <ios_system/ios_system.h>.
// That framework was removed (it was vestigial — LaTeX runs via BusyTeX WASM
// and math via SwiftMath/CoreText), so import UIKit explicitly here; the
// SwiftMath sources rely on it being visible through the bridging header.
#import <UIKit/UIKit.h>

// Original Metal shader types
#include "ShaderTypes.h"

// CodeBench C Interpreter (C89/C99/C23)
#include "codebench_cc.h"

// CodeBench C++ Interpreter
#include "codebench_cpp.h"

// CodeBench Fortran Interpreter
#include "codebench_fortran.h"



// LoRA fine-tune bridge (ported from QVAC fabric-llm.cpp's
// examples/llama.swiftui FinetuneBridge). Provides the
// `llama_swift_run_lora_finetune` C entry point that wraps the
// full LoRA training pipeline in a single call. Used by
// LlamaFinetuner.swift.
#include "FinetuneBridge.h"

#endif
