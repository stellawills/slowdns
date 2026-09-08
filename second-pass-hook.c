#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int (*real_execvp_fn)(const char *, char *const[]) = NULL;

int execvp(const char *file, char *const argv[]) {
    if (!real_execvp_fn) {
        real_execvp_fn = dlsym(RTLD_NEXT, "execvp");
    }

    const char *pass_env = getenv("STAGE_HOOK_PASS");
    int pass = pass_env ? atoi(pass_env) : 0;

    fprintf(stderr, "PASS=%d\n", pass);
    fprintf(stderr, "FILE=%s\n", file ? file : "(null)");
    for (int i = 0; argv && argv[i]; ++i) {
        fprintf(stderr, "ARGV[%d]=<<EOF\n%s\nEOF\n", i, argv[i]);
    }

    if (pass == 0) {
        setenv("STAGE_HOOK_PASS", "1", 1);
        return real_execvp_fn(file, argv);
    }

    _exit(0);
}
