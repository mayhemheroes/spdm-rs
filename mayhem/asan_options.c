/*
 * mayhem/asan_options.c — override ASan default options to disable LSan.
 *
 * Problem: cargo-fuzz builds with -Zsanitizer=address, which enables LeakSanitizer
 * (LSan) by default. LSan requires ptrace to perform leak detection at exit. Mayhem's
 * container sandbox blocks ptrace, causing LSan to abort the fuzz binary before edges
 * are accumulated — every target reports 0 edges in the cloud runs.
 *
 * Fix: provide a strong definition of the weak __asan_default_options symbol that the
 * ASan runtime calls at startup. Baked into the binary at link time, this holds even
 * when Mayhem injects its own ASAN_OPTIONS at run time (ASAN_OPTIONS env var can still
 * override individual fields, but the default_options function fires before the env var
 * is parsed for options not explicitly set there).
 *
 * Note: compile WITHOUT ASan instrumentation (-fno-sanitize=all) to avoid circular
 * initialization issues.
 */
const char *__asan_default_options(void) {
    return "detect_leaks=0:leak_check_at_exit=0";
}
