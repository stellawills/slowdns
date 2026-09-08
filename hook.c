#define _GNU_SOURCE
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>

int execvp(const char *file, char *const argv[]) {
    fprintf(stderr, "FILE=%s\n", file ? file : "(null)");
    for (int i = 0; argv && argv[i]; ++i) {
        fprintf(stderr, "ARGV[%d]=<<EOF\n%s\nEOF\n", i, argv[i]);
    }
    _exit(0);
}
