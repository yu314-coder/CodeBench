//
//  CodeBench-Bridging-Header.h
//

#ifndef CodeBench_Bridging_Header_h
#define CodeBench_Bridging_Header_h

#import <UIKit/UIKit.h>

// ios_system: provides initializeEnvironment() AND runs the framework's
// load-time setup that the iOS Python .fwork loader depends on to resolve
// @executable_path at dlopen time. Removing it broke runtime loading of
// hashlib / math / _md5 / etc. — DO NOT remove without a replacement.
#import <ios_system/ios_system.h>

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
