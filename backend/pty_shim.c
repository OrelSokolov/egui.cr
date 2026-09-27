/* pty_shim.c — cross-platform pseudoterminal for the egui-cr terminal.
 *
 * One small C API over the two OS primitives:
 *   Unix (Linux/macOS) : posix_openpt/grantpt/unlockpt + fork/setsid
 *                        (TIOCSCTTY makes the slave the controlling tty,
 *                        so job control and SIGWINCH behave like xterm's)
 *   Windows            : ConPTY (CreatePseudoConsole, Win10 1809+) with a
 *                        dedicated reader thread feeding a ring buffer
 *
 * The Crystal side (src/egui/terminal/pty.cr) calls egui_cr_pty_read from
 * a fiber: on Unix read(2) blocks that worker thread until the child
 * produces output (a blocked fiber is fine, a blocked frame is not);
 * on Windows read waits on a condition variable the reader thread
 * signals. Writes go straight through from the frame thread — terminal
 * input is tiny and the kernel pipe buffers absorb bursts.
 *
 * Lifecycle (two-phase, so a blocked reader never touches freed state):
 *   egui_cr_pty_close  — ask the child to die (SIGHUP / ClosePseudoConsole);
 *                        safe to call from any thread at any time
 *   egui_cr_pty_reap   — wait for the child, close everything, free.
 *                        Call ONCE, after read() has returned -1 (reader
 *                        done) or when the session is abandoned.
 */

#if defined(_WIN32)

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string.h>
#include <stdlib.h>

#ifndef PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
#define PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE 0x00020016
#endif

/* ConPTY is Win10 1809+; resolve it dynamically so binaries still load
 * (and fail cleanly at spawn) on older systems. */
typedef HRESULT(WINAPI *fn_CreatePseudoConsole)(COORD, HANDLE, HANDLE, DWORD, void **);
typedef void(WINAPI *fn_ResizePseudoConsole)(void *, COORD);
typedef void(WINAPI *fn_ClosePseudoConsole)(void *);

static fn_CreatePseudoConsole p_CreatePseudoConsole;
static fn_ResizePseudoConsole p_ResizePseudoConsole;
static fn_ClosePseudoConsole p_ClosePseudoConsole;
static int pty_conpty_resolved = 0;

static int conpty_resolve(void)
{
    if (pty_conpty_resolved) return p_CreatePseudoConsole != NULL;
    pty_conpty_resolved = 1;
    HMODULE k32 = GetModuleHandleW(L"kernel32.dll");
    if (!k32) return 0;
    p_CreatePseudoConsole = (fn_CreatePseudoConsole)(void *)GetProcAddress(k32, "CreatePseudoConsole");
    p_ResizePseudoConsole = (fn_ResizePseudoConsole)(void *)GetProcAddress(k32, "ResizePseudoConsole");
    p_ClosePseudoConsole = (fn_ClosePseudoConsole)(void *)GetProcAddress(k32, "ClosePseudoConsole");
    return p_CreatePseudoConsole != NULL;
}

typedef struct EguiCrPty {
    void *hpc;              /* HPCON */
    HANDLE h_in_w;          /* we write the child's stdin here */
    HANDLE h_out_r;         /* we read the child's stdout here */
    HANDLE h_proc;
    HANDLE reader;
    CRITICAL_SECTION lock;
    CONDITION_VARIABLE cv_data;   /* reader -> consumer: bytes arrived */
    unsigned char *ring;    /* cap is a power of two */
    size_t cap, head, tail; /* head = next write, tail = next read */
    volatile int closed;    /* close() called or reader hit EOF */
    int have_exit, exit_code;
} EguiCrPty;

/* spawn's error path calls it before the definition below */
void egui_cr_pty_reap(EguiCrPty *p);

static size_t ring_used(const EguiCrPty *p)
{
    return (p->head - p->tail) & (p->cap - 1);
}

static void ring_put(EguiCrPty *p, const unsigned char *src, size_t n)
{
    size_t pos = p->head & (p->cap - 1);
    size_t first = p->cap - pos;
    if (first > n) first = n;
    memcpy(p->ring + pos, src, first);
    memcpy(p->ring, src + first, n - first);
    p->head += n;
}

static void ring_get(EguiCrPty *p, unsigned char *dst, size_t n)
{
    size_t pos = p->tail & (p->cap - 1);
    size_t first = p->cap - pos;
    if (first > n) first = n;
    memcpy(dst, p->ring + pos, first);
    memcpy(dst + first, p->ring, n - first);
    p->tail += n;
}

/* Reader thread: ConPTY output pipe -> ring buffer. When the ring is
 * full it polls (10ms) instead of deadlocking; that is backpressure —
 * conhost stops writing until we drain, exactly like a full pty. */
static DWORD WINAPI reader_thread(LPVOID arg)
{
    EguiCrPty *p = (EguiCrPty *)arg;
    unsigned char buf[4096];
    DWORD n;
    for (;;) {
        if (!ReadFile(p->h_out_r, buf, sizeof buf, &n, NULL)) break;
        if (n == 0) break;
        EnterCriticalSection(&p->lock);
        while (p->cap - ring_used(p) < n && !p->closed) {
            LeaveCriticalSection(&p->lock);
            Sleep(10);
            EnterCriticalSection(&p->lock);
        }
        if (p->closed) { LeaveCriticalSection(&p->lock); break; }
        ring_put(p, buf, n);
        LeaveCriticalSection(&p->lock);
        WakeConditionVariable(&p->cv_data);
    }
    EnterCriticalSection(&p->lock);
    p->closed = 1;
    LeaveCriticalSection(&p->lock);
    WakeAllConditionVariable(&p->cv_data);
    return 0;
}

static wchar_t *utf8_to_utf16(const char *s, int *out_len)
{
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
    if (!w) return NULL;
    MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    if (out_len) *out_len = n - 1;
    return w;
}

/* UTF-16 environment block ("K=V\0K=V\0\0") from a NULL-terminated
 * UTF-8 "K=V" array; NULL -> inherit the parent environment. */
static wchar_t *build_env(const char *const *env)
{
    if (!env) return NULL;
    size_t total_wchars = 1; /* final double-NUL */
    for (const char *const *e = env; *e; e++) total_wchars += strlen(*e) + 1;
    wchar_t *block = (wchar_t *)malloc(total_wchars * sizeof(wchar_t));
    if (!block) return NULL;
    wchar_t *cursor = block;
    for (const char *const *e = env; *e; e++) {
        int n;
        wchar_t *w = utf8_to_utf16(*e, &n);
        if (!w) { free(block); return NULL; }
        /* memcpy, not wmemcpy: the wchar count is known and wmemcpy is
         * not in the old msvcrt import set Crystal links against */
        memcpy(cursor, w, ((size_t)n + 1) * sizeof(wchar_t));
        cursor += n + 1;
        free(w);
    }
    *cursor = 0;
    return block;
}

/* Command line from argv: quote every argument that contains a space. */
static wchar_t *build_cmdline(const char *const *argv)
{
    if (!argv || !argv[0]) return NULL;
    size_t cap = 4;
    for (const char *const *a = argv; *a; a++) cap += strlen(*a) + 4;
    char *cmd = (char *)calloc(cap, 1);
    if (!cmd) return NULL;
    char *cursor = cmd;
    for (const char *const *a = argv; *a; a++) {
        if (a != argv) *cursor++ = ' ';
        if (strchr(*a, ' ') && (*a)[0] != '"') {
            cursor += sprintf(cursor, "\"%s\"", *a);
        } else {
            strcpy(cursor, *a);
            cursor += strlen(*a);
        }
    }
    wchar_t *w = utf8_to_utf16(cmd, NULL);
    free(cmd);
    return w;
}

EguiCrPty *egui_cr_pty_spawn(const char *shell, const char *const *argv,
                             const char *cwd, const char *const *env,
                             int cols, int rows)
{
    if (!conpty_resolve()) return NULL;

    HANDLE pty_in_r = INVALID_HANDLE_VALUE, pty_in_w = INVALID_HANDLE_VALUE;
    HANDLE pty_out_r = INVALID_HANDLE_VALUE, pty_out_w = INVALID_HANDLE_VALUE;
    if (!CreatePipe(&pty_in_r, &pty_in_w, NULL, 0)) return NULL;
    if (!CreatePipe(&pty_out_r, &pty_out_w, NULL, 0)) {
        CloseHandle(pty_in_r); CloseHandle(pty_in_w);
        return NULL;
    }

    COORD size = {(SHORT)(cols > 0 ? cols : 80), (SHORT)(rows > 0 ? rows : 24)};
    void *hpc = NULL;
    HRESULT hr = p_CreatePseudoConsole(size, pty_in_r, pty_out_w, 0, &hpc);
    /* ConPTY duplicates both ends into conhost; ours are no longer needed. */
    CloseHandle(pty_in_r);
    CloseHandle(pty_out_w);
    if (hr != S_OK || !hpc) {
        CloseHandle(pty_in_w); CloseHandle(pty_out_r);
        return NULL;
    }

    STARTUPINFOEXW si;
    ZeroMemory(&si, sizeof si);
    si.StartupInfo.cb = sizeof si;
    size_t attr_size = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
    si.lpAttributeList = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(attr_size);
    if (!si.lpAttributeList ||
        !InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr_size) ||
        !UpdateProcThreadAttribute(si.lpAttributeList, 0,
                                   PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                   hpc, sizeof(void *), NULL, NULL)) {
        free(si.lpAttributeList);
        p_ClosePseudoConsole(hpc);
        CloseHandle(pty_in_w); CloseHandle(pty_out_r);
        return NULL;
    }

    /* argv[0] is the shell itself when the caller passes no args —
     * build_cmdline wants a full argv, so fill it in. */
    const char *fallback_argv[2] = {shell, NULL};
    const char *const *use_argv = (argv && argv[0]) ? argv : fallback_argv;
    wchar_t *cmdline = build_cmdline(use_argv);
    wchar_t *wcwd = cwd ? utf8_to_utf16(cwd, NULL) : NULL;
    wchar_t *wenv = build_env(env);
    PROCESS_INFORMATION pi;
    ZeroMemory(&pi, sizeof pi);

    EguiCrPty *p = NULL;
    if (cmdline && CreateProcessW(NULL, cmdline, NULL, NULL, FALSE,
                                  /* CREATE_UNICODE_ENVIRONMENT is mandatory:
                                   * wenv is a UTF-16 block; without the flag
                                   * CreateProcessW fails with 87 */
                                  EXTENDED_STARTUPINFO_PRESENT |
                                      CREATE_UNICODE_ENVIRONMENT,
                                  wenv, wcwd, &si.StartupInfo, &pi)) {
        p = (EguiCrPty *)calloc(1, sizeof *p);
        p->hpc = hpc;
        p->h_in_w = pty_in_w;
        p->h_out_r = pty_out_r;
        p->h_proc = pi.hProcess;
        CloseHandle(pi.hThread); /* only the process handle is needed */
        p->cap = 1u << 20; /* 1 MiB */
        p->ring = (unsigned char *)malloc(p->cap);
        InitializeCriticalSection(&p->lock);
        InitializeConditionVariable(&p->cv_data);
        p->reader = CreateThread(NULL, 0, reader_thread, p, 0, NULL);
        hpc = NULL; pty_in_w = pty_out_r = INVALID_HANDLE_VALUE;
    }

    free(cmdline);
    free(wcwd);
    free(wenv);
    DeleteProcThreadAttributeList(si.lpAttributeList);
    free(si.lpAttributeList);
    if (hpc) p_ClosePseudoConsole(hpc);
    if (pty_in_w != INVALID_HANDLE_VALUE) CloseHandle(pty_in_w);
    if (pty_out_r != INVALID_HANDLE_VALUE) CloseHandle(pty_out_r);
    if (!p) return NULL;
    if (!p->ring || !p->reader) { egui_cr_pty_reap(p); return NULL; }
    return p;
}

int egui_cr_pty_read(EguiCrPty *p, unsigned char *buf, int len)
{
    if (!p || len <= 0) return -1;
    EnterCriticalSection(&p->lock);
    for (;;) {
        size_t used = ring_used(p);
        if (used > 0) {
            size_t n = used < (size_t)len ? used : (size_t)len;
            ring_get(p, buf, n);
            LeaveCriticalSection(&p->lock);
            return (int)n;
        }
        if (p->closed) { LeaveCriticalSection(&p->lock); return -1; }
        if (!SleepConditionVariableCS(&p->cv_data, &p->lock, 250)) {
            /* timeout: loop and re-check (also catches close races) */
        }
    }
}

/* Non-blocking drain of the ring buffer (frame-driven polling). */
int egui_cr_pty_read_poll(EguiCrPty *p, unsigned char *buf, int len)
{
    if (!p || len <= 0) return -1;
    EnterCriticalSection(&p->lock);
    size_t used = ring_used(p);
    if (used == 0) {
        int over = p->closed;
        LeaveCriticalSection(&p->lock);
        return over ? -1 : 0;
    }
    size_t n = used < (size_t)len ? used : (size_t)len;
    ring_get(p, buf, n);
    LeaveCriticalSection(&p->lock);
    return (int)n;
}

int egui_cr_pty_write(EguiCrPty *p, const unsigned char *buf, int len)
{
    if (!p || len <= 0) return -1;
    DWORD n = 0;
    if (!WriteFile(p->h_in_w, buf, (DWORD)len, &n, NULL)) return -1;
    return (int)n;
}

void egui_cr_pty_resize(EguiCrPty *p, int cols, int rows)
{
    if (!p || !p->hpc || !p_ResizePseudoConsole) return;
    COORD size = {(SHORT)(cols > 0 ? cols : 80), (SHORT)(rows > 0 ? rows : 24)};
    p_ResizePseudoConsole(p->hpc, size);
}

/* -2 = still running, else exit code. */
int egui_cr_pty_wait(EguiCrPty *p, int blocking)
{
    if (!p) return -1;
    if (!p->have_exit) {
        DWORD code = 0;
        if (blocking) WaitForSingleObject(p->h_proc, INFINITE);
        if (GetExitCodeProcess(p->h_proc, &code) && code != STILL_ACTIVE) {
            p->exit_code = (int)code;
            p->have_exit = 1;
        }
    }
    return p->have_exit ? p->exit_code : -2;
}

int egui_cr_pty_alive(EguiCrPty *p)
{
    return p ? egui_cr_pty_wait(p, 0) == -2 : 0;
}

/* The read end as a CRT fd for evented (IOCP) reads in Crystal. The
 * ring-buffer path does not use it; -1 = poll the ring instead. */
int egui_cr_pty_fd(EguiCrPty *p)
{
    (void)p;
    return -1;
}

/* Unix-only concept (see the Unix side); no fd to hand over here. */
void egui_cr_pty_release_fd(EguiCrPty *p)
{
    (void)p;
}

void egui_cr_pty_close(EguiCrPty *p)
{
    if (!p) return;
    /* Closing the ConPTY terminates the attached client; the reader
     * thread then hits EOF and marks the session closed. */
    if (p->hpc) { p_ClosePseudoConsole(p->hpc); p->hpc = NULL; }
    TerminateProcess(p->h_proc, 0); /* belt and braces for stragglers */
    EnterCriticalSection(&p->lock);
    p->closed = 1;
    LeaveCriticalSection(&p->lock);
    WakeAllConditionVariable(&p->cv_data);
}

void egui_cr_pty_reap(EguiCrPty *p)
{
    if (!p) return;
    if (p->hpc) { p_ClosePseudoConsole(p->hpc); p->hpc = NULL; }
    egui_cr_pty_close(p);
    if (p->reader) { WaitForSingleObject(p->reader, INFINITE); CloseHandle(p->reader); }
    if (p->h_proc) {
        WaitForSingleObject(p->h_proc, 5000);
        egui_cr_pty_wait(p, 1);
        CloseHandle(p->h_proc);
    }
    if (p->h_in_w != INVALID_HANDLE_VALUE) CloseHandle(p->h_in_w);
    if (p->h_out_r != INVALID_HANDLE_VALUE) CloseHandle(p->h_out_r);
    DeleteCriticalSection(&p->lock);
    free(p->ring);
    free(p);
}

#else /* ------------------------------------------------------------ Unix */

#define _XOPEN_SOURCE 600
#define _DEFAULT_SOURCE 1
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#endif

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/wait.h>

extern char **environ;

/* macOS has no ptsname_r; ptsname uses a static buffer but spawn is
 * called from a single thread, so a copy right away is safe. */
static int pty_slave_name(int master, char *buf, size_t len)
{
#if defined(__APPLE__)
    char *name = ptsname(master);
    if (!name) return -1;
    if (strlen(name) >= len) return -1;
    strcpy(buf, name);
    return 0;
#else
    return ptsname_r(master, buf, len);
#endif
}

typedef struct EguiCrPty {
    int master;
    int pid;
    volatile int closed;
    int have_exit, exit_code;
} EguiCrPty;

EguiCrPty *egui_cr_pty_spawn(const char *shell, const char *const *argv,
                             const char *cwd, const char *const *env,
                             int cols, int rows)
{
    if (!shell) return NULL;

    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) return NULL;
    if (grantpt(master) != 0 || unlockpt(master) != 0) {
        close(master);
        return NULL;
    }
    char slave_name[128];
    if (pty_slave_name(master, slave_name, sizeof slave_name) != 0) {
        close(master);
        return NULL;
    }

    struct winsize ws;
    memset(&ws, 0, sizeof ws);
    ws.ws_col = (unsigned short)(cols > 0 ? cols : 80);
    ws.ws_row = (unsigned short)(rows > 0 ? rows : 24);
    ioctl(master, TIOCSWINSZ, &ws);

    sigset_t mask, old;
    sigemptyset(&mask);
    sigaddset(&mask, SIGCHLD);
    sigprocmask(SIG_BLOCK, &mask, &old); /* fork+exec without a SIGCHLD race */

    int pid = fork();
    if (pid == 0) {
        /* child: new session, slave becomes the controlling terminal */
        sigprocmask(SIG_SETMASK, &old, NULL);
        setsid();
        int slave = open(slave_name, O_RDWR);
        if (slave < 0) _exit(127);
        ioctl(slave, TIOCSCTTY, (char *)0);
        dup2(slave, 0);
        dup2(slave, 1);
        dup2(slave, 2);
        if (slave > 2) close(slave);
        close(master);
        if (cwd && chdir(cwd) != 0) { /* keep going in / on failure */ }
        const char *fallback_argv[2] = {shell, NULL};
        const char *const *use_argv = (argv && argv[0]) ? argv : fallback_argv;
        char **use_env = env ? (char **)env : environ;
        execve(shell, (char *const *)use_argv, use_env);
        _exit(127);
    }
    sigprocmask(SIG_SETMASK, &old, NULL);
    if (pid < 0) {
        close(master);
        return NULL;
    }

    EguiCrPty *p = (EguiCrPty *)calloc(1, sizeof *p);
    if (!p) { close(master); kill(pid, SIGKILL); return NULL; }
    p->master = master;
    p->pid = pid;
    return p;
}

int egui_cr_pty_read(EguiCrPty *p, unsigned char *buf, int len)
{
    if (!p || len <= 0) return -1;
    for (;;) {
        ssize_t n = read(p->master, buf, (size_t)len);
        if (n > 0) return (int)n;
        if (n == 0) return -1;                    /* EOF */
        if (errno == EINTR) continue;
        return -1; /* EIO: child side closed (it exited) — session over */
    }
}

int egui_cr_pty_write(EguiCrPty *p, const unsigned char *buf, int len)
{
    if (!p || len <= 0) return -1;
    size_t done = 0;
    while (done < (size_t)len) {
        ssize_t n = write(p->master, buf + done, (size_t)len - done);
        if (n > 0) { done += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        return done > 0 ? (int)done : -1;
    }
    return (int)done;
}

void egui_cr_pty_resize(EguiCrPty *p, int cols, int rows)
{
    if (!p) return;
    struct winsize ws;
    memset(&ws, 0, sizeof ws);
    ws.ws_col = (unsigned short)(cols > 0 ? cols : 80);
    ws.ws_row = (unsigned short)(rows > 0 ? rows : 24);
    ioctl(p->master, TIOCSWINSZ, &ws); /* kernel signals the foreground pgid */
}

/* -2 = still running, else exit code (128+sig when signaled). */
int egui_cr_pty_wait(EguiCrPty *p, int blocking)
{
    if (!p) return -1;
    if (!p->have_exit) {
        int st;
        int r = waitpid(p->pid, &st, blocking ? 0 : WNOHANG);
        if (r == p->pid) {
            p->exit_code = WIFEXITED(st) ? WEXITSTATUS(st)
                          : WIFSIGNALED(st) ? 128 + WTERMSIG(st) : -1;
            p->have_exit = 1;
        } else if (r < 0 && errno == ECHILD) {
            p->exit_code = -1;
            p->have_exit = 1;
        }
    }
    return p->have_exit ? p->exit_code : -2;
}

int egui_cr_pty_alive(EguiCrPty *p)
{
    return p ? egui_cr_pty_wait(p, 0) == -2 : 0;
}

/* The master fd — Crystal wraps it in IO::FileDescriptor for evented
 * (epoll/kqueue) reads; blocking reads from a fiber would wedge the
 * Crystal scheduler. The shim owns the fd (reap closes it) UNLESS the
 * Crystal side called egui_cr_pty_release_fd: then Crystal's IO#close
 * owns the close (it must also deregister the fd from the scheduler's
 * poller, which a close(2) behind its back cannot do). */
int egui_cr_pty_fd(EguiCrPty *p)
{
    return p ? p->master : -1;
}

/* Hand the master fd's close over to the caller (Crystal): reap will
 * skip close(2) on it. Crystal's poller indexes fd state by fd NUMBER,
 * so a foreign close(2) leaves stale state; the next pty reuses the
 * same number and the scheduler wedges. On ring-buffer platforms
 * (Windows) this is a no-op. */
void egui_cr_pty_release_fd(EguiCrPty *p)
{
    if (!p) return;
    p->master = -1;
}

/* Non-blocking read: bytes now available, 0 = none, -1 = over. Only
 * meaningful on the ring-buffer platforms; Unix sessions use the fd. */
int egui_cr_pty_read_poll(EguiCrPty *p, unsigned char *buf, int len)
{
    (void)p; (void)buf; (void)len;
    return -1;
}

void egui_cr_pty_close(EguiCrPty *p)
{
    if (!p || p->closed) return;
    p->closed = 1;
    /* Hang up the controlling terminal: the child dies, every remaining
     * slave descriptor goes away and an evented read on master reports
     * EIO/EOF. Do NOT close(master) here — reap owns it. */
    kill(p->pid, SIGHUP);
    kill(p->pid, SIGCONT); /* a stopped child must notice the HUP */
}

void egui_cr_pty_reap(EguiCrPty *p)
{
    if (!p) return;
    egui_cr_pty_close(p);
    kill(p->pid, SIGKILL); /* reap is terminal: never let it linger */
    int st;
    while (waitpid(p->pid, &st, 0) < 0 && errno == EINTR) {}
    /* master < 0: the fd was released to Crystal (release_fd) — its
     * IO#close already closed it; closing here could hit a reused fd */
    if (p->master >= 0) close(p->master);
    free(p);
}

#endif
