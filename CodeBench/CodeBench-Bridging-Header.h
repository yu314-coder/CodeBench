//
//  CodeBench-Bridging-Header.h
//

#ifndef CodeBench_Bridging_Header_h
#define CodeBench_Bridging_Header_h

// Original Metal shader types
#include "ShaderTypes.h"

// CodeBench C Interpreter (C89/C99/C23)
#include "codebench_cc.h"

// CodeBench C++ Interpreter
#include "codebench_cpp.h"

// CodeBench Fortran Interpreter
#include "codebench_fortran.h"

// LaTeX Engine (pdftex via lib-tex + ios_system)
#import <ios_system/ios_system.h>

// pdftex library entry point
extern int dllpdftexmain(int argc, char *argv[]);

#endif
