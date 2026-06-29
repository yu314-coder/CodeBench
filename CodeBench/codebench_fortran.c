/*
 * codebench_fortran.c — intentionally (almost) empty.
 *
 * CodeBench's Fortran interpreter is ofort (Beliavsky, MIT) — see
 * ofort/LICENSE and codebench_fortran.h. The ofort core lives in
 * CodeBench/ofort/*.c and is compiled DIRECTLY by the app target: this
 * Xcode project uses a "synchronized" folder group, so every .c under
 * CodeBench/ (including ofort/) is built automatically. Those translation
 * units are the single definition of the public ofort_create /
 * ofort_execute / ofort_get_output / ofort_get_error / ofort_destroy /
 * ofort_reset symbols that codebench_fortran.h declares.
 *
 * NOTE: an earlier revision #included the ofort .c files here (an
 * amalgamation). Under a synchronized folder that compiled ofort a SECOND
 * time, producing "53 duplicate symbols" at link. Keeping this file empty
 * leaves ofort/*.c as the only definition.
 */
typedef int codebench_fortran_amalgamation_removed_t;
