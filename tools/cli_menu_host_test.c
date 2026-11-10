/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * cli_menu_host_test.c -- host test of the generated CLI menu (fw_c64/cli/menu.c): parse and
 * dispatch. The command list is read independently from fw_c64/cli/cli_commands.txt, so a menu.c
 * that drifts from it fails. Every command is driven with a synthesized line (upper, lower and
 * mixed case); missing required and surplus arguments, unknown commands, empty and over-long
 * lines, HELP / ? / EXIT, help column alignment and Menu_ParseU32 are checked. Callbacks are
 * recording stubs generated from fw_c64/cli/menu_commands.def.
 *
 * Build and run (MSYS2 UCRT64, from the repo root):
 *   gcc -std=c11 -Wall -Wextra -Werror -pedantic -Ifw_c64/cli tools/cli_menu_host_test.c \
 *       fw_c64/cli/menu.c -o build/cli_menu_host_test.exe
 *   build/cli_menu_host_test.exe fw_c64/cli/cli_commands.txt [+INJECT_FAILURE]
 * +INJECT_FAILURE expects a wrong function for the first command: the run must then FAIL
 * (negative control). Prints "TEST PASS: cli_menu_host" or "TEST FAIL" (exit 1).
 */
#include "menu.h"

#include <stdio.h>
#include <string.h>

#define MAX_CMDS 64
#define OUT_MAX  8192

static int  g_checks;
static int  g_errors;
static int  g_inject;
static char g_out[OUT_MAX];
static int  g_called;                    /* function index of the last callback, -1 none */
static int  g_call_argc;
static char g_call_argv[MENU_MAX_ARGS][64];
static int  g_call_count;

static const char *const g_func_names[] = {
#define MENU_CMD(f) #f,
#include "menu_commands.def"
#undef MENU_CMD
};
#define NFUNC ((int)(sizeof(g_func_names) / sizeof(g_func_names[0])))

typedef struct
{
    char func[512];
    char syntax[512];
    int  nreq;
    int  nopt;
    int  nkw;
} cmd_t;

static cmd_t g_cmd[MAX_CMDS];
static int   g_ncmd;

/* menu_write -- host output sink: append to g_out. */
void menu_write(const char *text)
{
    size_t n = strlen(g_out);

    if (n + strlen(text) < OUT_MAX) {
        strcpy(g_out + n, text);
    }
}

static void check(int ok, const char *what)
{
    g_checks++;
    if (!ok) {
        g_errors++;
        printf("  FAIL: %s\n", what);
    }
}

static int record(int idx, const MenuCommandContext *ctx)
{
    int i;

    g_called = idx;
    g_call_argc = ctx->argc;
    g_call_count++;
    for (i = 0; i < ctx->argc && i < MENU_MAX_ARGS; i++) {
        strncpy(g_call_argv[i], ctx->argv[i], sizeof(g_call_argv[i]) - 1u);
        g_call_argv[i][sizeof(g_call_argv[i]) - 1u] = '\0';
    }
    return 0;
}

#define MENU_CMD(f) int f(const MenuCommandContext *ctx) { return record(__COUNTER__, ctx); }
#include "menu_commands.def"
#undef MENU_CMD

static void reset(void)
{
    g_out[0] = '\0';
    g_called = -1;
    g_call_argc = -1;
    g_call_count = 0;
}

static int func_index(const char *name)
{
    int i;

    for (i = 0; i < NFUNC; i++) {
        if (strcmp(g_func_names[i], name) == 0) {
            return i;
        }
    }
    return -1;
}

static void load_txt(const char *path)
{
    FILE *f = fopen(path, "r");
    char line[512];

    if (f == NULL) {
        printf("cannot open %s\n", path);
        g_errors++;
        return;
    }
    while (fgets(line, (int)sizeof(line), f) != NULL && g_ncmd < MAX_CMDS) {
        char *c1;
        char *c2;
        char *tok;
        cmd_t *c = &g_cmd[g_ncmd];

        if (line[0] == '#' || line[0] == '\n' || line[0] == '\r') {
            continue;
        }
        c1 = strchr(line, ':');
        c2 = (c1 != NULL) ? strchr(c1 + 1, ':') : NULL;
        if (c2 == NULL) {
            continue;
        }
        *c1 = '\0';
        *c2 = '\0';
        snprintf(c->func, sizeof(c->func), "%s", line);
        snprintf(c->syntax, sizeof(c->syntax), "%s", c1 + 1);
        for (tok = c->syntax; *tok != '\0'; tok++) {
            if (*tok == '[') {
                c->nreq++;
            } else if (*tok == '{') {
                c->nopt++;
            }
        }
        g_ncmd++;
    }
    fclose(f);
}

/* build -- synthesize an input line: keywords (case mode 0 upper, 1 lower, 2 mixed), nreq required
 * and nopt optional parameters "p0".."pN" (a param token is "p<i>" so argv can be compared). */
static void build(const cmd_t *c, int mode, int nreq, int nopt, char *out, size_t n)
{
    char syn[512];
    char *tok;
    int req = 0;
    int opt = 0;
    int pi = 0;
    int kw = 0;

    out[0] = '\0';
    snprintf(syn, sizeof(syn), "%s", c->syntax);
    for (tok = strtok(syn, " "); tok != NULL; tok = strtok(NULL, " ")) {
        char piece[512];
        size_t k;

        if (tok[0] == '[') {
            if (req++ >= nreq) {
                continue;
            }
            snprintf(piece, sizeof(piece), "p%d", pi++);
        } else if (tok[0] == '{') {
            if (opt++ >= nopt) {
                continue;
            }
            snprintf(piece, sizeof(piece), "p%d", pi++);
        } else {
            snprintf(piece, sizeof(piece), "%s", tok);
            for (k = 0u; piece[k] != '\0'; k++) {
                if (mode == 1 || (mode == 2 && ((k + (size_t)kw) & 1u))) {
                    if (piece[k] >= 'A' && piece[k] <= 'Z') {
                        piece[k] = (char)(piece[k] - 'A' + 'a');
                    }
                }
            }
            kw++;
        }
        strncat(out, piece, n - strlen(out) - 1u);
        strncat(out, " ", n - strlen(out) - 1u);
    }
}

static void test_commands(void)
{
    int i;
    int mode;

    for (i = 0; i < g_ncmd; i++) {
        const cmd_t *c = &g_cmd[i];
        const int expect = (g_inject && i == 0) ? func_index(g_cmd[g_ncmd - 1].func) : func_index(c->func);
        char line[256];
        int nopt;
        int j;

        check(func_index(c->func) >= 0, "command file function exists in menu_commands.def");
        for (mode = 0; mode < 3; mode++) {
            for (nopt = 0; nopt <= c->nopt; nopt++) {
                reset();
                build(c, mode, c->nreq, nopt, line, sizeof(line));
                check(Menu_ProcessLine(line) == 0, line);
                check(g_called == expect, "dispatched to the expected callback");
                check(g_call_argc == c->nreq + nopt, "argument count");
                for (j = 0; j < g_call_argc && j < MENU_MAX_ARGS; j++) {
                    char want[8];

                    snprintf(want, sizeof(want), "p%d", j);
                    check(strcmp(g_call_argv[j], want) == 0, "argument value in order");
                }
            }
        }
        if (c->nreq > 0) {
            reset();
            build(c, 0, c->nreq - 1, 0, line, sizeof(line));
            check(Menu_ProcessLine(line) == -1 && g_call_count == 0, "missing required parameter is refused");
            check(strstr(g_out, "Bad arguments") != NULL, "missing parameter gives the Bad arguments message");
        }
        reset();
        build(c, 0, c->nreq, c->nopt, line, sizeof(line));
        strncat(line, "extra", sizeof(line) - strlen(line) - 1u);
        check(Menu_ProcessLine(line) == -1 && g_call_count == 0, "surplus argument is refused");
    }
}

static void test_misc(void)
{
    char longline[MENU_LINE_MAX + 20];
    char out1[OUT_MAX];
    const char *p;
    int col = -1;
    int lines = 0;

    reset();
    check(Menu_ProcessLine("") == 0 && g_call_count == 0 && g_out[0] == '\0', "empty line is silent");
    check(Menu_ProcessLine("   \t ") == 0 && g_call_count == 0, "blank line is silent");
    reset();
    check(Menu_ProcessLine("FROBNICATE 1 2") == -1 && g_call_count == 0, "unknown command refused");
    check(strstr(g_out, "Unknown command") != NULL, "unknown command message");
    reset();
    check(Menu_ProcessLine("VERS") == -1 && g_call_count == 0, "keyword prefix does not match");
    check(Menu_ProcessLine(NULL) == -1, "NULL line");
    memset(longline, 'A', sizeof(longline));
    longline[sizeof(longline) - 1u] = '\0';
    reset();
    check(Menu_ProcessLine(longline) == -1 && strstr(g_out, "too long") != NULL, "over-long line refused");
    check(Menu_ProcessLine("EXIT") == MENU_EXIT && Menu_ProcessLine("exit") == MENU_EXIT, "EXIT");
    reset();
    check(Menu_ProcessLine("HELP") == 0, "HELP returns 0");
    snprintf(out1, sizeof(out1), "%s", g_out);
    reset();
    check(Menu_ProcessLine("?") == 0 && strcmp(g_out, out1) == 0, "? prints the same as HELP");
    reset();
    check(Menu_ProcessLine("help") == 0 && strcmp(g_out, out1) == 0, "help is case-insensitive");
    for (p = out1; *p != '\0';) {
        const char *eol = strchr(p, '\n');
        const char *dash = strstr(p, " - ");

        if (eol == NULL) {
            break;
        }
        check(dash != NULL && dash < eol, "help line has a separator");
        if (dash != NULL) {
            if (col < 0) {
                col = (int)(dash - p);
            }
            check((int)(dash - p) == col, "help separators share one column");
        }
        lines++;
        p = eol + 1;
    }
    check(lines == g_ncmd + 3, "help lists every command plus HELP, ? and EXIT");
    {
        unsigned long v = 0ul;

        check(Menu_ParseU32("123", &v) && v == 123ul, "parse decimal");
        check(Menu_ParseU32("0x4000", &v) && v == 0x4000ul, "parse hex");
        check(Menu_ParseU32("0XfF", &v) && v == 255ul, "parse hex case");
        check(Menu_ParseU32("4294967295", &v) && v == 0xFFFFFFFFul, "parse max");
        check(!Menu_ParseU32("4294967296", &v), "parse overflow");
        check(!Menu_ParseU32("12x", &v) && !Menu_ParseU32("", &v) && !Menu_ParseU32("0x", &v) &&
              !Menu_ParseU32("-1", &v), "parse rejects junk");
    }
}

int main(int argc, char **argv)
{
    int i;

    for (i = 2; i < argc; i++) {
        if (strcmp(argv[i], "+INJECT_FAILURE") == 0) {
            g_inject = 1;
        }
    }
    if (argc < 2) {
        printf("usage: %s cli_commands.txt [+INJECT_FAILURE]\n", argv[0]);
        return 2;
    }
    load_txt(argv[1]);
    check(g_ncmd > 0 && g_ncmd == NFUNC, "command file and menu_commands.def have the same count");
    test_commands();
    test_misc();
    printf("%d checks, %d errors\n", g_checks, g_errors);
    if (g_errors != 0) {
        printf("TEST FAIL: cli_menu_host\n");
        return 1;
    }
    printf("TEST PASS: cli_menu_host\n");
    return 0;
}
