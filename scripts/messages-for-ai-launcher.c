#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *role_for_name(const char *name) {
  if (strcmp(name, "imessage-drafts-mcp") == 0) return "imessage-mcp";
  if (strcmp(name, "ghostie-mcp") == 0) return "ghostie-mcp";
  if (strcmp(name, "imessage-drafts-daemon") == 0) return "imessage-daemon";
  if (strcmp(name, "whatsapp-drafts-mcp") == 0) return "whatsapp-mcp";
  if (strcmp(name, "whatsapp-drafts-daemon") == 0) return "whatsapp-daemon";
  if (strcmp(name, "wrapped-generator") == 0) return "wrapped";
  if (strcmp(name, "texting-analytics-generator") == 0) return "texting-analytics";
  if (strcmp(name, "birthday-generator") == 0) return "birthday";
  return NULL;
}

static int launcher_path(char *out, size_t out_len) {
  char raw[PATH_MAX];
  uint32_t raw_len = (uint32_t)sizeof(raw);
  if (_NSGetExecutablePath(raw, &raw_len) != 0) return -1;
  if (realpath(raw, out) != NULL) return 0;
  if (raw[0] == '/') {
    snprintf(out, out_len, "%s", raw);
    return 0;
  }
  char cwd[PATH_MAX];
  if (getcwd(cwd, sizeof(cwd)) == NULL) return -1;
  snprintf(out, out_len, "%s/%s", cwd, raw);
  return 0;
}

int main(int argc, char **argv) {
  char path[PATH_MAX];
  if (argc < 1 || launcher_path(path, sizeof(path)) != 0) {
    fprintf(stderr, "messages-for-ai-launcher: unable to resolve launcher path: %s\n", strerror(errno));
    return 127;
  }

  char name_buf[PATH_MAX];
  snprintf(name_buf, sizeof(name_buf), "%s", path);
  const char *role = role_for_name(basename(name_buf));
  if (role == NULL) {
    fprintf(stderr, "messages-for-ai-launcher: unknown launcher name %s\n", argv[0]);
    return 127;
  }

  char dir_buf[PATH_MAX];
  snprintf(dir_buf, sizeof(dir_buf), "%s", path);
  char backend[PATH_MAX];
  snprintf(backend, sizeof(backend), "%s/messages-for-ai-backend", dirname(dir_buf));

  char **child_argv = calloc((size_t)argc + 2, sizeof(char *));
  if (child_argv == NULL) {
    fprintf(stderr, "messages-for-ai-launcher: calloc failed\n");
    return 127;
  }
  child_argv[0] = backend;
  child_argv[1] = (char *)role;
  for (int i = 1; i < argc; i++) child_argv[i + 1] = argv[i];
  child_argv[argc + 1] = NULL;

  execv(backend, child_argv);
  fprintf(stderr, "messages-for-ai-launcher: execv %s failed: %s\n", backend, strerror(errno));
  return 127;
}
