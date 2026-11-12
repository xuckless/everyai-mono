// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.
//
// everyai-exec: starts a program in a session (and process group) of its own, in place: `everyai-exec /abs/prog
// args...` calls setsid() and execv()s the program, so its pid is the one the app started, its group and session
// are that pid, and it has no controlling terminal. The app resolves the path itself (no PATH search here) and
// checks beforehand what can be checked (exists, a file, executable, a script's interpreter). A file the kernel
// won't run (ENOEXEC: a script without `#!`) is run by /bin/sh, as execvp does. Any other exec failure is printed
// to stderr and the exit code is 127, like a shell's.
// See frontend/lib/core/process/supervisor_io.dart.
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: everyai-exec /absolute/program [args...]\n");
    return 127;
  }
  if (setsid() < 0) {
    fprintf(stderr, "everyai-exec: setsid: %s\n", strerror(errno));
    return 125;
  }
  execv(argv[1], argv + 1);
  if (errno == ENOEXEC) {
    // argv[0] is "everyai-exec": reuse the slot for the shell (argv has argc + 1 entries, the last NULL).
    char **sh = calloc((size_t)argc + 1, sizeof(char *));
    if (sh != NULL) {
      sh[0] = "/bin/sh";
      for (int i = 1; i < argc; i++) sh[i] = argv[i];
      execv("/bin/sh", sh);
    }
  }
  fprintf(stderr, "everyai-exec: %s: %s\n", argv[1], strerror(errno));
  return 127;
}
