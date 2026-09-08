#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int pass_num(void) {
    const char *p = getenv("STAGE_HOOK_PASS");
    return p ? atoi(p) : 0;
}

static void dump(const char *fn, const char *file, char *const argv[]) {
    fprintf(stderr, "PASS=%d\nFN=%s\nFILE=%s\n", pass_num(), fn, file ? file : "(null)");
    for (int i = 0; argv && argv[i]; ++i) {
        fprintf(stderr, "ARGV[%d]=<<EOF\n%s\nEOF\n", i, argv[i]);
    }
}

int execvp(const char *file, char *const argv[]) {
    static int (*real_fn)(const char *, char *const[]) = NULL;
    if (!real_fn) real_fn = dlsym(RTLD_NEXT, "execvp");
    dump("execvp", file, argv);
    if (pass_num() == 0) {
        setenv("STAGE_HOOK_PASS", "1", 1);
        return real_fn(file, argv);
    }
    _exit(0);
}

int execve(const char *file, char *const argv[], char *const envp[]) {
    static int (*real_fn)(const char *, char *const[], char *const[]) = NULL;
    if (!real_fn) real_fn = dlsym(RTLD_NEXT, "execve");
    dump("execve", file, argv);
    if (pass_num() == 0) {
        setenv("STAGE_HOOK_PASS", "1", 1);
        return real_fn(file, argv, envp);
    }
    _exit(0);
}
