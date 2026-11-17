/*
 * The C client as a command, in the contract License Worker's
 * `npm run check:clients` drives (LW_C_CLIENT=<this binary>):
 *
 *   lw_cli <state-file> activate <key> | check | deactivate
 *
 * Env: LW_URL, LW_PUBLIC_KEYS (JSON kid -> key), LW_PRODUCT_IDS (comma list).
 * Prints one JSON line. Also a complete example of the C interface.
 */
#include "license_worker.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_KEYS 8
#define MAX_PRODUCTS 16

static const char *env(const char *name) {
  const char *v = getenv(name);
  return v ? v : "";
}

/* Reads {"k1":"...","k2":"..."}: kids and base64 keys hold no quotes or escapes. */
static size_t parse_keys(char *json, const char **kids, const char **keys) {
  size_t n = 0;
  char *p = json;
  while (n < MAX_KEYS) {
    char *k0 = strchr(p, '"'); if (!k0) break;
    char *k1 = strchr(k0 + 1, '"'); if (!k1) break;
    char *v0 = strchr(k1 + 1, '"'); if (!v0) break;
    char *v1 = strchr(v0 + 1, '"'); if (!v1) break;
    *k1 = '\0';
    *v1 = '\0';
    kids[n] = k0 + 1;
    keys[n] = v0 + 1;
    n++;
    p = v1 + 1;
  }
  return n;
}

static size_t parse_ids(const char *list, int64_t *ids) {
  size_t n = 0;
  const char *p = list;
  while (*p && n < MAX_PRODUCTS) {
    char *end;
    long long v = strtoll(p, &end, 10);
    if (end != p) ids[n++] = (int64_t)v;
    p = (*end == ',') ? end + 1 : (end == p ? p + 1 : end);
  }
  return n;
}

static void print_json_string(const char *s) {
  if (!s) { fputs("null", stdout); return; }
  putchar('"');
  for (; *s; s++) {
    unsigned char c = (unsigned char)*s;
    if (c == '"' || c == '\\') printf("\\%c", c);
    else if (c < 0x20) printf("\\u%04x", c);
    else putchar(c);
  }
  putchar('"');
}

static const char *state_name(LwState s) {
  switch (s) {
    case LW_STATE_VALID: return "valid";
    case LW_STATE_GRACE: return "grace";
    case LW_STATE_INACTIVE: return "inactive";
    case LW_STATE_REVOKED: return "revoked";
  }
  return "unknown";
}

static void print_status(const LwStatus *st) {
  printf("{\"unlocked\":%s,\"state\":\"%s\"", st->unlocked ? "true" : "false", state_name(st->state));
  if (st->unlocked) {
    printf(",\"offline\":%s", st->offline ? "true" : "false");
  } else {
    fputs(",\"reason\":", stdout);
    print_json_string(st->reason);
  }
  putchar('}');
}

static void print_failure(char *message) {
  fputs("{\"ok\":false,\"error\":", stdout);
  print_json_string(message);
  puts("}");
  lw_string_free(message);
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: lw_cli <state-file> activate <key> | check | deactivate\n");
    puts("{\"error\":\"usage\"}");
    return 2;
  }

  char *keys_json = strdup(env("LW_PUBLIC_KEYS"));
  const char *kids[MAX_KEYS], *keys[MAX_KEYS];
  int64_t products[MAX_PRODUCTS];

  LwConfig cfg = {0};
  cfg.server_url = env("LW_URL");
  cfg.key_count = parse_keys(keys_json, kids, keys);
  cfg.key_ids = kids;
  cfg.public_keys = keys;
  cfg.product_count = parse_ids(env("LW_PRODUCT_IDS"), products);
  cfg.product_ids = products;
  cfg.instance_name = "check-clients";
  cfg.timeout_ms = 3000;
  cfg.storage_path = argv[1];

  char *error = NULL;
  LwClient *client = lw_client_new(&cfg, &error);
  if (!client) {
    print_failure(error);
    free(keys_json);
    return 1;
  }

  const char *cmd = argv[2];
  LwStatus st = {0};
  char *message = NULL;
  if (strcmp(cmd, "activate") == 0) {
    LwResult r = lw_activate(client, argc > 3 ? argv[3] : "", &st, &message);
    if (r == LW_RESULT_OK) {
      fputs("{\"ok\":true,\"status\":", stdout);
      print_status(&st);
      puts("}");
    } else {
      print_failure(message);
    }
  } else if (strcmp(cmd, "check") == 0) {
    lw_check(client, &st);
    print_status(&st);
    putchar('\n');
  } else if (strcmp(cmd, "deactivate") == 0) {
    if (lw_deactivate(client, &message) == LW_RESULT_OK) puts("{\"ok\":true}");
    else print_failure(message);
  } else {
    puts("{\"error\":\"usage\"}");
  }

  lw_status_clear(&st);
  lw_client_free(client);
  free(keys_json);
  return 0;
}
