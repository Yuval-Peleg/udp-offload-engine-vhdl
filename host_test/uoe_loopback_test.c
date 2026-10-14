/*
 * uoe_loopback_test -- host-side bring-up test for the UDP offload engine.
 *
 * Runs on an ordinary Ubuntu PC whose NIC is cabled to the dev board. The board
 * is expected to be built with rx_udp's output looped back into tx_udp's input,
 * so every payload sent to it comes straight back.
 *
 * Plain BSD sockets -- no raw sockets, no root. That is deliberate: the kernel
 * ARPs for the board on its own, so arp_handler is exercised by a real stack
 * rather than by something this program hand-builds.
 *
 * ---------------------------------------------------------------------------
 * ADDRESSING -- read this before wondering why nothing comes back
 * ---------------------------------------------------------------------------
 * The board's transmit destination is STATIC configuration, not a reflection of
 * whoever sent the packet:
 *
 *      tx_eth   dst MAC  <- conf_tx_dst_mac
 *      tx_ipv4  dst IP   <- conf_tx_dst_ip
 *      tx_udp   dst port <- conf_tx_dst_port,  src port <- conf_port
 *
 * So the reply does NOT come back to this program's ephemeral source port.
 * Three things must line up or packets vanish silently:
 *
 *   1. this PC's IP must equal conf_tx_dst_ip
 *   2. this PC's MAC must equal conf_tx_dst_mac -- the board only ANSWERS ARP,
 *      it never asks, so it cannot discover your MAC by itself
 *   3. --local-port must equal conf_tx_dst_port
 *
 * The receive direction is far less fussy: rx_eth checks the destination MAC,
 * rx_ipv4 the destination IP, and rx_udp does not filter on port at all.
 *
 * ---------------------------------------------------------------------------
 * TWO MODES
 * ---------------------------------------------------------------------------
 * latency (default)   one packet in flight, every reply verified byte for byte
 *                     against a per-sequence pattern. Answers "is it correct?".
 *
 * throughput (--speed) packets streamed without waiting for replies. For each
 *                     size the tool SEARCHES for the highest rate the link
 *                     sustains and reports it. Answers "how fast does it go?".
 *
 * ---------------------------------------------------------------------------
 * THREE THINGS THAT STOP THE HOST BEING MEASURED INSTEAD OF THE BOARD
 * ---------------------------------------------------------------------------
 *  1. batching. One sendto() per packet cannot reach 10 Gbps at small payloads
 *     (an 18-byte payload at line rate is 14.9 Mpps = 67 ns per packet, less
 *     than a syscall costs anywhere), so both directions use sendmmsg/recvmmsg.
 *
 *  2. a payload template. fill_payload() runs a byte-at-a-time xorshift;
 *     generating it per packet on send AND regenerating it to verify on
 *     receive caps the tool at a few Gbps. Throughput mode builds one
 *     template per size and rewrites only the 4-byte sequence number, verifying
 *     with memcmp. Latency mode keeps the per-sequence pattern.
 *
 *  3. a reader thread. Sending must be PACED and receiving must be CONTINUOUS;
 *     one loop cannot do both, and time spent waiting to send is time the
 *     socket is not read, so replies pile up until the kernel discards them.
 *     A separate reader makes the socket buffer size stop mattering, which is
 *     what lets this work on a stock machine -- SO_RCVBUFFORCE and
 *     net.core.rmem_max both need root, reading promptly does not.
 *
 * ---------------------------------------------------------------------------
 *      make                                    (static; see the Makefile)
 *      ./uoe_loopback_test --board-ip 192.168.1.1 --local-port 4660
 *      ./uoe_loopback_test --board-ip 192.168.1.1 --local-port 4660 --speed
 *      ./uoe_loopback_test ... --speed --jumbo --report run.txt
 * ---------------------------------------------------------------------------
 */

#define _GNU_SOURCE          /* sendmmsg / recvmmsg */

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define ETH_MIN_FRAME  60
#define UOE_HEADERS    42      /* 14 Ethernet + 20 IPv4 + 8 UDP */
#define WIRE_EXTRA     24      /* preamble+SFD 8, FCS 4, IFG 12 */

#define MTU_PAYLOAD    1472    /* 1500 MTU - 20 - 8 */
#define JUMBO_PAYLOAD  8958    /* 9000 MTU - 20 - 8; needs MTU 9000 */
#define MAX_PAYLOAD    JUMBO_PAYLOAD

#define MAX_BURST      400000
#define MAX_BATCH      256

/* what the kernel actually granted, which is not what was asked for */
static int g_rcvbuf = 0, g_sndbuf = 0;

static volatile sig_atomic_t interrupted = 0;
static void on_sigint(int s) { (void)s; interrupted = 1; }

struct config {
    const char *board_ip;
    uint16_t    board_port, local_port;
    int         count;              /* packets per size, latency mode */
    int         timeout_ms;
    int         gap_us;
    int         fixed_size;         /* -1 = sweep */
    bool        speed, jumbo, soak, verbose;
    int         rate_pct;           /* -1 = search for it */
    int         duration_ms;        /* per throughput probe */
    double      loss_tol;           /* % loss still counted as sustained */
    int         batch;
    double      line_gbps;
    const char *report;
};

struct result {
    int    size;
    long   sent, received, lost, corrupt, wrong_len, wrong_src, dup, reordered;
    long   host_drops;              /* the KERNEL discarded these */
    long   tx_fail;                 /* never left this PC */
    double rtt_min, rtt_avg, rtt_max;
    double offered_gbps, achieved_gbps, achieved_mpps;
    int    rate_pct, probes;
    bool   burst_capped;            /* MAX_BURST cut the probe short */
    double peak_gbps;               /* best any probe reached, search aside */
    double ceil_design_gbps, ceil_wire_gbps;
    double elapsed_ms;
    bool   ok;
};

/* ------------------------------------------------------------------ */
/* rate model                                                          */
/* ------------------------------------------------------------------ */

/* The figure from tx_udp.vhd's header: only the headers this design adds,
 * plus its padding of short payloads up to the 60-byte minimum frame. */
static double ceil_design_bps(int payload, double line_bps)
{
    if (payload <= 0) return 0.0;
    int frame = payload + UOE_HEADERS;
    if (frame < ETH_MIN_FRAME) frame = ETH_MIN_FRAME;
    return line_bps * (double)payload / (double)frame;
}

/* What the medium will carry, counting the parts of an Ethernet frame that
 * never reach the UOE. Diverges from the design figure at small payloads. */
static double wire_pps(int payload, double line_bps)
{
    int frame = payload + UOE_HEADERS;
    if (frame < ETH_MIN_FRAME) frame = ETH_MIN_FRAME;
    return line_bps / (8.0 * (double)(frame + WIRE_EXTRA));
}

static double ceil_wire_bps(int payload, double line_bps)
{
    if (payload <= 0) return 0.0;
    return wire_pps(payload, line_bps) * (double)payload * 8.0;
}

/* ------------------------------------------------------------------ */
/* payload pattern                                                     */
/* ------------------------------------------------------------------ */

static uint32_t xs32(uint32_t *s)
{
    uint32_t x = *s;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return *s = x;
}

/* Bytes 0..3 carry the sequence when there is room; that is what lets a reply
 * be matched to its request. */
static void fill_payload(uint8_t *buf, int len, uint32_t seq)
{
    uint32_t s = seq * 2654435761u + 1u;      /* never zero: xorshift sticks */
    int i = 0;
    if (len >= 4) { uint32_t be = htonl(seq); memcpy(buf, &be, 4); i = 4; }
    for (; i < len; i++) buf[i] = (uint8_t)(xs32(&s) >> 24);
}

static int check_payload(const uint8_t *buf, int len, uint32_t seq)
{
    uint32_t s = seq * 2654435761u + 1u;
    int i = 0;
    if (len >= 4) {
        uint32_t be; memcpy(&be, buf, 4);
        if (ntohl(be) != seq) return 0;
        i = 4;
    }
    for (; i < len; i++)
        if (buf[i] != (uint8_t)(xs32(&s) >> 24)) return i;
    return -1;
}

static bool seq_recoverable(int len) { return len >= 4; }
static uint32_t seq_of(const uint8_t *b) { uint32_t v; memcpy(&v, b, 4); return ntohl(v); }

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

/* ------------------------------------------------------------------ */
/* host-side drop accounting                                           */
/* ------------------------------------------------------------------ */

/* Packets the kernel dropped BEFORE they reached our socket, because the
 * per-CPU backlog filled. /proc/net/udp does not see these -- it only counts
 * socket-buffer overflow -- so without this they look like board loss.
 * netdev_max_backlog defaults to 1000, which is nothing at 10G. */
static long softnet_drops(void)
{
    FILE *f = fopen("/proc/net/softnet_stat", "r");
    if (!f) return -1;
    long total = 0;
    unsigned long processed, dropped;
    char line[512];
    while (fgets(line, sizeof line, f))
        if (sscanf(line, "%lx %lx", &processed, &dropped) == 2)
            total += (long)dropped;
    fclose(f);
    return total;
}

/* Packets the KERNEL discarded because this program did not read them fast
 * enough. Without this they are indistinguishable from packets the board never
 * sent, and the board gets blamed for the host's socket buffer.
 *
 * /proc/net/udp's last column is the per-socket drop counter; the socket is
 * found by its local port, which is unique here because we bind to a fixed
 * one. Returns -1 if it cannot be read. */
static long udp_socket_drops(uint16_t port)
{
    long drops = -1;
    for (int pass = 0; pass < 2; pass++) {
        FILE *f = fopen(pass == 0 ? "/proc/net/udp" : "/proc/net/udp6", "r");
        if (!f) continue;
        char line[512];
        if (!fgets(line, sizeof line, f)) { fclose(f); continue; }   /* header */
        while (fgets(line, sizeof line, f)) {
            unsigned lport = 0;
            char laddr[128];
            if (sscanf(line, "%*d: %127[0-9A-Fa-f]:%X", laddr, &lport) != 2) continue;
            if (lport != port) continue;
            char *tok = strtok(line, " \t\n"), *last = NULL;
            while (tok) { last = tok; tok = strtok(NULL, " \t\n"); }
            if (last) {
                if (drops < 0) drops = 0;
                drops += strtol(last, NULL, 10);
            }
        }
        fclose(f);
    }
    return drops;
}

/* ------------------------------------------------------------------ */
/* latency mode -- one in flight, per-sequence pattern verified         */
/* ------------------------------------------------------------------ */

static int latency_size(int sock, const struct sockaddr_in *board,
                        const struct config *cfg, int size,
                        uint32_t *next_seq, struct result *r)
{
    static uint8_t tx[MAX_PAYLOAD], rx[MAX_PAYLOAD + 64];
    double sum = 0.0; long n = 0;
    double t_start = now_ms();

    memset(r, 0, sizeof *r);
    r->size = size;
    r->rtt_min = 1e30;

    for (int i = 0; i < cfg->count && !interrupted; i++) {
        uint32_t seq = (*next_seq)++;
        fill_payload(tx, size, seq);

        if (sendto(sock, tx, (size_t)size, 0,
                   (const struct sockaddr *)board, sizeof *board) < 0) {
            fprintf(stderr, "sendto: %s\n", strerror(errno));
            return -1;
        }
        r->sent++;
        double t0 = now_ms();

        /* A zero-length payload is not a drivable AXI-Stream packet, so the
         * board has nothing to send. Silence is the correct answer; check for
         * it rather than skipping the case. */
        if (size == 0) {
            struct pollfd p = { .fd = sock, .events = POLLIN };
            if (poll(&p, 1, 20) > 0) {
                ssize_t got = recv(sock, rx, sizeof rx, 0);
                fprintf(stderr, "  size 0: unexpected %zd-byte reply\n", got);
                r->corrupt++;
            }
            continue;
        }

        for (;;) {
            struct pollfd p = { .fd = sock, .events = POLLIN };
            int pr = poll(&p, 1, cfg->timeout_ms);
            if (pr == 0) {
                r->lost++;
                if (cfg->verbose)
                    fprintf(stderr, "  seq %u (%d B): no reply\n", seq, size);
                break;
            }
            if (pr < 0) { if (errno == EINTR) break; perror("poll"); return -1; }

            struct sockaddr_in from; socklen_t fl = sizeof from;
            ssize_t got = recvfrom(sock, rx, sizeof rx, 0,
                                   (struct sockaddr *)&from, &fl);
            if (got < 0) { perror("recvfrom"); return -1; }
            r->received++;

            if (from.sin_addr.s_addr != board->sin_addr.s_addr) {
                char a[INET_ADDRSTRLEN];
                inet_ntop(AF_INET, &from.sin_addr, a, sizeof a);
                fprintf(stderr, "  reply from %s, not the board\n", a);
                r->wrong_src++;
                continue;
            }
            if (got != size) {
                fprintf(stderr, "  seq %u: %zd bytes back, sent %d\n", seq, got, size);
                r->wrong_len++;
                break;
            }
            if (seq_recoverable(size) && seq_of(rx) != seq) {
                uint32_t g = seq_of(rx);
                if (g < seq) { r->reordered++; continue; }   /* late straggler */
                fprintf(stderr, "  seq %u: reply carries %u\n", seq, g);
                r->corrupt++;
                break;
            }
            int off = check_payload(rx, (int)got, seq);
            if (off >= 0) {
                static uint8_t want[MAX_PAYLOAD];
                fill_payload(want, size, seq);
                fprintf(stderr, "  seq %u (%d B): byte %d is %02X, expected %02X\n",
                        seq, size, off, rx[off], want[off]);
                r->corrupt++;
                break;
            }

            double rtt = now_ms() - t0;
            if (rtt < r->rtt_min) r->rtt_min = rtt;
            if (rtt > r->rtt_max) r->rtt_max = rtt;
            sum += rtt; n++;
            break;
        }

        if (cfg->gap_us > 0) usleep((useconds_t)cfg->gap_us);
    }

    r->elapsed_ms = now_ms() - t_start;
    r->rtt_avg = n ? sum / (double)n : 0.0;
    if (!n) r->rtt_min = 0.0;
    r->ceil_design_gbps = ceil_design_bps(size, cfg->line_gbps * 1e9) / 1e9;
    r->ceil_wire_gbps   = ceil_wire_bps(size, cfg->line_gbps * 1e9) / 1e9;
    r->ok = (r->lost == 0 && r->corrupt == 0 &&
             r->wrong_len == 0 && r->wrong_src == 0);
    return 0;
}

/* ------------------------------------------------------------------ */
/* throughput mode                                                     */
/* ------------------------------------------------------------------ */

struct reader_ctx {
    int      sock, size, batch;
    long     burst;
    uint32_t base;
    const struct sockaddr_in *board;
    const uint8_t *templ;
    uint8_t  *seen;
    const double *sent_at;

    /* written only by the reader, read by main after joining */
    long   received, corrupt, wrong_len, wrong_src, dup;
    double rtt_min, rtt_max, rtt_sum;
    long   rtt_n;

    volatile int stop;
};

static void *reader_thread(void *arg)
{
    struct reader_ctx *c = arg;
    int batch = c->batch;

    struct mmsghdr *m = calloc((size_t)batch, sizeof *m);
    struct iovec   *v = calloc((size_t)batch, sizeof *v);
    uint8_t *buf = malloc((size_t)batch * (size_t)(MAX_PAYLOAD + 64));
    struct sockaddr_in *from = calloc((size_t)batch, sizeof *from);
    if (!m || !v || !buf || !from) { free(m); free(v); free(buf); free(from); return NULL; }

    for (int i = 0; i < batch; i++) {
        v[i].iov_base = buf + (size_t)i * (MAX_PAYLOAD + 64);
        v[i].iov_len  = MAX_PAYLOAD + 64;
        m[i].msg_hdr.msg_iov     = &v[i];
        m[i].msg_hdr.msg_iovlen  = 1;
        m[i].msg_hdr.msg_name    = &from[i];
        m[i].msg_hdr.msg_namelen = sizeof from[i];
    }

    c->rtt_min = 1e30;

    while (!c->stop) {
        struct pollfd p = { .fd = c->sock, .events = POLLIN };
        if (poll(&p, 1, 20) <= 0) continue;   /* 20 ms: notice stop promptly */

        int got = recvmmsg(c->sock, m, (unsigned)batch, MSG_DONTWAIT, NULL);
        if (got <= 0) continue;

        for (int q = 0; q < got; q++) {
            const uint8_t *pl = v[q].iov_base;
            int len = (int)m[q].msg_len;
            c->received++;
            if (from[q].sin_addr.s_addr != c->board->sin_addr.s_addr) {
                c->wrong_src++; continue;
            }
            if (len != c->size) { c->wrong_len++; continue; }
            if (len < 4) continue;
            uint32_t s2 = seq_of(pl);
            if (s2 < c->base || s2 >= c->base + (uint32_t)c->burst) {
                c->corrupt++; continue;
            }
            uint32_t idx = s2 - c->base;
            if (c->seen[idx]) { c->dup++; continue; }
            if (len > 4 && memcmp(pl + 4, c->templ + 4, (size_t)len - 4) != 0) {
                c->corrupt++; continue;
            }
            c->seen[idx] = 1;
            double rtt = now_ms() - c->sent_at[idx];
            if (rtt < c->rtt_min) c->rtt_min = rtt;
            if (rtt > c->rtt_max) c->rtt_max = rtt;
            c->rtt_sum += rtt; c->rtt_n++;
        }
    }

    free(m); free(v); free(buf); free(from);
    return NULL;
}

static int speed_size(int sock, const struct sockaddr_in *board,
                      const struct config *cfg, int size, int rate_pct,
                      uint32_t *next_seq, struct result *r)
{
    double ceil_wire  = ceil_wire_bps(size, cfg->line_gbps * 1e9);
    double target_bps = ceil_wire * (double)rate_pct / 100.0;
    double pps        = target_bps / (8.0 * (double)size);

    /* A probe runs for a fixed TIME, not a fixed packet count. At 18 bytes the
     * ceiling is ~14 Mpps, so a fixed count would finish in a millisecond and
     * measure startup jitter; at jumbo it would take minutes. */
    long want_burst = (long)(pps * (double)cfg->duration_ms / 1000.0);
    long burst = want_burst;
    if (burst < 200)       burst = 200;
    if (burst > MAX_BURST) burst = MAX_BURST;

    int batch = cfg->batch;
    if (batch > MAX_BATCH)   batch = MAX_BATCH;
    if (batch < 1)           batch = 1;
    if ((long)batch > burst) batch = (int)burst;

    size_t plen = (size_t)(size > 0 ? size : 1);
    uint8_t *seen    = calloc((size_t)burst, 1);
    double  *sent_at = calloc((size_t)burst, sizeof(double));
    uint8_t *txbuf   = malloc((size_t)batch * plen);
    uint8_t *templ   = malloc(plen);
    struct mmsghdr *msgs = calloc((size_t)batch, sizeof *msgs);
    struct iovec   *iov  = calloc((size_t)batch, sizeof *iov);

    if (!seen || !sent_at || !txbuf || !templ || !msgs || !iov) {
        perror("calloc");
        free(seen); free(sent_at); free(txbuf); free(templ); free(msgs); free(iov);
        return -1;
    }

    /* built once; only the sequence number changes per packet */
    fill_payload(templ, size, 0);
    for (int i = 0; i < batch; i++)
        memcpy(txbuf + (size_t)i * plen, templ, plen);

    uint32_t base = *next_seq;
    memset(r, 0, sizeof *r);
    r->size = size;
    r->rate_pct = rate_pct;
    r->ceil_design_gbps = ceil_design_bps(size, cfg->line_gbps * 1e9) / 1e9;
    r->ceil_wire_gbps   = ceil_wire / 1e9;
    r->offered_gbps     = target_bps / 1e9;
    r->rtt_min = 1e30;

    long drops_before = udp_socket_drops(cfg->local_port);
    long soft_before  = softnet_drops();

    struct reader_ctx rc;
    memset(&rc, 0, sizeof rc);
    rc.sock = sock; rc.size = size; rc.batch = batch; rc.burst = burst;
    rc.base = base; rc.board = board; rc.templ = templ;
    rc.seen = seen; rc.sent_at = sent_at;

    pthread_t reader;
    if (pthread_create(&reader, NULL, reader_thread, &rc) != 0) {
        perror("pthread_create");
        free(seen); free(sent_at); free(txbuf); free(templ); free(msgs); free(iov);
        return -1;
    }

    double t0 = now_ms();
    double next_tx = t0;
    double batch_ms = (double)batch * 1000.0 / pps;

    long i = 0;
    while (i < burst && !interrupted) {
        int k = (int)((burst - i) < batch ? (burst - i) : batch);

        for (int q = 0; q < k; q++) {
            uint8_t *b = txbuf + (size_t)q * plen;
            if (size >= 4) {
                uint32_t be = htonl((uint32_t)(base + i + q));
                memcpy(b, &be, 4);              /* the only per-packet work */
            }
            iov[q].iov_base = b;
            iov[q].iov_len  = (size_t)size;
            msgs[q].msg_hdr.msg_iov     = &iov[q];
            msgs[q].msg_hdr.msg_iovlen  = 1;
            msgs[q].msg_hdr.msg_name    = (void *)board;
            msgs[q].msg_hdr.msg_namelen = sizeof *board;
            msgs[q].msg_len = 0;
        }

        /* Wait for the slot. The reader thread keeps draining, so this can
         * spin -- and it has to: nanosleep oversleeps by tens of microseconds
         * on a stock kernel, which would overshoot the pacing and cap the
         * rate, while clock_gettime is cheap enough to spin on. Only long
         * waits are worth sleeping through. */
        for (;;) {
            double d = next_tx - now_ms();
            if (d <= 0.0 || interrupted) break;
            if (d > 0.3) {
                struct timespec ts = { .tv_sec = 0,
                                       .tv_nsec = (long)((d - 0.15) * 1e6) };
                nanosleep(&ts, NULL);
            }
        }
        next_tx += batch_ms * (double)k / (double)batch;

        double now = now_ms();
        for (int q = 0; q < k; q++) sent_at[i + q] = now;

        int sent = sendmmsg(sock, msgs, (unsigned)k, 0);
        if (sent < 0) {
            if (errno == ENOBUFS || errno == EAGAIN || errno == EINTR) {
                /* These never reached the wire, so they are NOT sent;
                 * counting them would blame the board for this PC. */
                r->tx_fail += k; i += k; continue;
            }
            fprintf(stderr, "sendmmsg: %s\n", strerror(errno));
            rc.stop = 1; pthread_join(reader, NULL);
            free(seen); free(sent_at); free(txbuf); free(templ); free(msgs); free(iov);
            return -1;
        }
        r->sent += sent;
        if (sent < k) r->tx_fail += k - sent;      /* short send, same reasoning */
        i += k;
    }
    *next_seq = base + (uint32_t)i;

    double t_send_done = now_ms();

    /* let the tail arrive, then stop the reader and take its numbers */
    struct timespec tail = { .tv_sec = cfg->timeout_ms / 1000,
                             .tv_nsec = (long)(cfg->timeout_ms % 1000) * 1000000L };
    nanosleep(&tail, NULL);
    rc.stop = 1;
    pthread_join(reader, NULL);

    r->received  = rc.received;
    r->corrupt   = rc.corrupt;
    r->wrong_len = rc.wrong_len;
    r->wrong_src = rc.wrong_src;
    r->dup       = rc.dup;
    if (rc.rtt_n) { r->rtt_min = rc.rtt_min; r->rtt_max = rc.rtt_max; }
    r->rtt_avg = rc.rtt_n ? rc.rtt_sum / (double)rc.rtt_n : 0.0;
    if (!rc.rtt_n) r->rtt_min = 0.0;

    long drops_after = udp_socket_drops(cfg->local_port);
    if (drops_before >= 0 && drops_after >= drops_before)
        r->host_drops = drops_after - drops_before;
    long soft_after = softnet_drops();
    if (soft_before >= 0 && soft_after >= soft_before)
        r->host_drops += soft_after - soft_before;

    r->elapsed_ms = t_send_done - t0;
    long got_ok = 0;
    for (long q = 0; q < burst; q++) if (seen[q]) got_ok++;
    r->lost = r->sent - got_ok - r->corrupt - r->wrong_len - r->dup;
    if (r->lost < 0) r->lost = 0;

    double secs = r->elapsed_ms / 1000.0;
    r->achieved_gbps = secs > 0 ? (double)got_ok * size * 8.0 / secs / 1e9 : 0;
    r->achieved_mpps = secs > 0 ? (double)got_ok / secs / 1e6 : 0;
    r->burst_capped  = (want_burst > MAX_BURST);
    r->ok = (r->lost == 0 && r->corrupt == 0 &&
             r->wrong_len == 0 && r->wrong_src == 0);

    free(seen); free(sent_at); free(txbuf); free(templ); free(msgs); free(iov);
    return 0;
}

/* ------------------------------------------------------------------ */
/* automatic rate search                                               */
/* ------------------------------------------------------------------ */

static bool sustained(const struct result *r, double loss_tol)
{
    if (r->corrupt || r->wrong_len || r->wrong_src) return false;
    if (r->sent <= 0) return false;
    /* Loss the kernel caused is not the board failing to keep up. Subtract it
     * before judging, or a slow reader here walks the search down and the
     * board is credited with a ceiling it never hit. */
    long board_loss = r->lost - r->host_drops;
    if (board_loss < 0) board_loss = 0;
    return 100.0 * (double)board_loss / (double)r->sent <= loss_tol;
}

/* Bisect rather than ramp: the failure is a cliff -- the queue either keeps up
 * or backs up and never recovers -- so bisection lands on it in about six
 * probes instead of twenty. 100% is tried first because a healthy datapath at
 * a large payload passes it outright and then no search is needed. */
static int auto_speed_size(int sock, const struct sockaddr_in *board,
                           const struct config *cfg, int size,
                           uint32_t *next_seq, struct result *best)
{
    struct result r;
    int lo = 0, hi = 100, probes = 0;

    memset(best, 0, sizeof *best);
    best->size = size;

    if (speed_size(sock, board, cfg, size, 100, next_seq, &r) < 0) return -1;
    probes++;
    if (cfg->verbose)
        fprintf(stderr, "    %d B @100%%: %ld lost (%ld hostdrop) of %ld -> %s\n",
                size, r.lost, r.host_drops, r.sent,
                sustained(&r, cfg->loss_tol) ? "ok" : "no");

    double peak = r.achieved_gbps;

    if (sustained(&r, cfg->loss_tol)) {
        *best = r; lo = 100;
    } else {
        /* Keep the failing probe, so a size where nothing sustained still
         * reports its detail instead of all zeroes. */
        *best = r;
        /* Stop at 3% apart: finer than the run-to-run variation of a UDP
         * socket on a general-purpose kernel, so more probes would only be
         * measuring the host. */
        while (hi - lo > 3 && !interrupted) {
            int mid = (lo + hi) / 2;
            if (speed_size(sock, board, cfg, size, mid, next_seq, &r) < 0) return -1;
            probes++;
            bool good = sustained(&r, cfg->loss_tol);
            if (cfg->verbose)
                fprintf(stderr, "    %d B @%3d%%: %ld lost (%ld hostdrop) of %ld -> %s\n",
                        size, mid, r.lost, r.host_drops, r.sent, good ? "ok" : "no");
            if (r.achieved_gbps > peak) peak = r.achieved_gbps;
            if (good) { lo = mid; *best = r; }
            else { hi = mid; if (lo == 0) *best = r; }   /* keep the evidence */
        }
    }

    best->size = size;
    best->rate_pct = lo;
    best->probes = probes;
    /* The highest goodput ANY probe reached, whatever the search concluded.
     * One probe lost to host drops sends the bisection down and six probes
     * cannot climb back, so the verdict swings run to run while this number
     * does not. It is a floor on what the link did, not a claim that the rate
     * is sustainable. */
    best->peak_gbps = peak;
    best->ceil_design_gbps = ceil_design_bps(size, cfg->line_gbps * 1e9) / 1e9;
    best->ceil_wire_gbps   = ceil_wire_bps(size, cfg->line_gbps * 1e9) / 1e9;
    /* lo == 0 means even the lowest probe lost packets: nothing was sustained,
     * which is a failure however good the numbers at the top looked. */
    best->ok = (lo > 0);
    return 0;
}

/* ------------------------------------------------------------------ */
/* reporting                                                           */
/* ------------------------------------------------------------------ */

/* A key for the table, printed once per run. The columns that get misread --
 * hostdrop and txfail especially -- are exactly the ones that decide whether a
 * number is the board's fault or this PC's. */
static void legend_latency(void)
{
    printf("  columns\n");
    printf("    size      UDP payload bytes sent per packet\n");
    printf("    sent      packets transmitted\n");
    printf("    recv      replies that arrived from the board\n");
    printf("    lost      sent but never came back\n");
    printf("    corrupt   came back with the wrong bytes, or the wrong sequence number\n");
    printf("    badlen    came back a different length than was sent\n");
    printf("    reord     arrived after a later packet -- not loss, but out of order\n");
    printf("    rtt       round trip, min / average / max, in ms\n\n");
}

static void legend_speed(void)
{
    printf("  columns\n");
    printf("    size       UDP payload bytes per packet\n");
    printf("    probes     how many rates were tried to find the one below\n");
    printf("    rate       the highest offered rate that held, as %% of the wire ceiling\n");
    printf("    sustained  goodput actually MEASURED at that rate -- the answer\n");
    printf("    Mpps       packets per second at that rate, in millions\n");
    printf("    lost       sent but never came back. Blamed on the board\n");
    printf("    hostdrop   arrived but THIS PC's kernel threw them away (/proc/net/udp, softnet_stat).\n");
    printf("               Not board loss; excluded from the search\n");
    printf("    txfail     never left this PC at all (ENOBUFS or a short send).\n");
    printf("               Not board loss; not counted as sent\n");
    printf("    corrupt    came back with the wrong bytes\n");
    printf("    design     ceiling from tx_udp.vhd: LINE x payload/max(payload+42, 60)\n");
    printf("    wire       ceiling once Ethernet's own overhead is counted too --\n");
    printf("               preamble 8, FCS 4, gap 12, and the 60-byte minimum frame.\n");
    printf("               Pacing aims at this one; the summary compares against design\n\n");
}

static void header_latency(void)
{
    printf("   size    sent   recv   lost  corrupt  badlen  reord   "
           "rtt min/avg/max ms      result\n");
    printf("  ------  ------ ------ ------ -------- ------- ------  "
           "----------------------  ------\n");
}

static void row_latency(const struct result *r)
{
    printf("  %6d  %6ld %6ld %6ld %8ld %7ld %6ld  %6.3f/%6.3f/%6.3f  %s\n",
           r->size, r->sent, r->received, r->lost, r->corrupt,
           r->wrong_len, r->reordered, r->rtt_min, r->rtt_avg, r->rtt_max,
           r->ok ? "ok" : "FAIL");
}

static void header_speed(void)
{
    printf("   size   probes  rate   sustained   Mpps    lost  hostdrop "
           " txfail corrupt   design   wire   result\n");
    printf("  ------  ------ -----  ----------- ------  ------ -------- "
           "------- ------- -------- ------  ------\n");
}

static void row_speed(const struct result *r)
{
    printf("  %6d  %6d  %3d%%  %8.3f G %6.3f  %6ld %8ld %7ld %7ld %8.3f %6.3f  %s\n",
           r->size, r->probes, r->rate_pct, r->achieved_gbps, r->achieved_mpps,
           r->lost, r->host_drops, r->tx_fail, r->corrupt,
           r->ceil_design_gbps, r->ceil_wire_gbps,
           r->ok ? "ok" : "FAIL");
}

/* Everything needed to interpret a run somewhere else, later, without the
 * machine in front of you. The host settings are the point: the same table
 * means different things depending on net.core.rmem_max and what the kernel
 * actually granted, and those are invisible in the terminal output. */
static void write_report(const struct config *cfg, const struct result *res,
                         size_t nsizes, const struct result *total,
                         int failures, int sweeps)
{
    FILE *f = fopen(cfg->report, "w");
    if (!f) { fprintf(stderr, "--report %s: %s\n", cfg->report, strerror(errno)); return; }

    time_t now = time(NULL);
    char when[64];
    strftime(when, sizeof when, "%Y-%m-%d %H:%M:%S", localtime(&now));

    fprintf(f, "uoe_loopback_test report\ngenerated %s\n\n", when);

    fprintf(f, "[run]\n");
    fprintf(f, "mode           = %s\n", cfg->speed ? "throughput" : "latency");
    fprintf(f, "board_ip       = %s\n", cfg->board_ip);
    fprintf(f, "board_port     = %u\n", cfg->board_port);
    fprintf(f, "local_port     = %u\n", cfg->local_port);
    fprintf(f, "line_gbps      = %g\n", cfg->line_gbps);
    fprintf(f, "jumbo          = %s\n", cfg->jumbo ? "yes" : "no");
    fprintf(f, "batch          = %d\n", cfg->batch);
    fprintf(f, "duration_ms    = %d\n", cfg->duration_ms);
    fprintf(f, "loss_tol_pct   = %g\n", cfg->loss_tol);
    fprintf(f, "count          = %d\n", cfg->count);
    fprintf(f, "timeout_ms     = %d\n", cfg->timeout_ms);
    fprintf(f, "rate_pct       = %s\n", cfg->rate_pct < 0 ? "auto" : "pinned");
    fprintf(f, "sweeps         = %d\n", sweeps);
    fprintf(f, "failures       = %d\n\n", failures);

    fprintf(f, "[host]\n");
    fprintf(f, "so_rcvbuf_granted = %d\n", g_rcvbuf);
    fprintf(f, "so_sndbuf_granted = %d\n", g_sndbuf);
    static const char *knobs[] = {
        "/proc/sys/net/core/rmem_max", "/proc/sys/net/core/wmem_max",
        "/proc/sys/net/core/rmem_default", "/proc/sys/net/core/netdev_max_backlog",
    };
    for (size_t i = 0; i < sizeof knobs / sizeof *knobs; i++) {
        FILE *k = fopen(knobs[i], "r");
        long v = -1;
        if (k) { if (fscanf(k, "%ld", &v) != 1) v = -1; fclose(k); }
        fprintf(f, "%-37s = %ld\n", knobs[i], v);
    }
    fprintf(f, "\n[results]\n");
    fprintf(f, "# size probes rate_pct sustained_gbps mpps sent recv lost "
               "hostdrop txfail corrupt wrong_len wrong_src dup reord "
               "rtt_min rtt_avg rtt_max offered_gbps ceil_design ceil_wire "
               "probe_ms burst_capped peak_gbps ok\n");
    for (size_t i = 0; i < nsizes; i++) {
        const struct result *r = &res[i];
        fprintf(f, "%d %d %d %.4f %.4f %ld %ld %ld %ld %ld %ld %ld %ld %ld %ld "
                   "%.4f %.4f %.4f %.4f %.4f %.4f %.1f %d %.4f %d\n",
                r->size, r->probes, r->rate_pct, r->achieved_gbps, r->achieved_mpps,
                r->sent, r->received, r->lost, r->host_drops, r->tx_fail,
                r->corrupt, r->wrong_len, r->wrong_src, r->dup, r->reordered,
                r->rtt_min, r->rtt_avg, r->rtt_max, r->offered_gbps,
                r->ceil_design_gbps, r->ceil_wire_gbps,
                r->elapsed_ms, r->burst_capped ? 1 : 0, r->peak_gbps,
                r->ok ? 1 : 0);
    }
    fprintf(f, "\n[totals]\n");
    fprintf(f, "sent=%ld recv=%ld lost=%ld hostdrop=%ld txfail=%ld corrupt=%ld "
               "wrong_len=%ld wrong_src=%ld dup=%ld reord=%ld\n",
            total->sent, total->received, total->lost, total->host_drops,
            total->tx_fail, total->corrupt, total->wrong_len, total->wrong_src,
            total->dup, total->reordered);

    fclose(f);
    printf("  report written to %s\n", cfg->report);
}

/* ------------------------------------------------------------------ */

static void usage(const char *me)
{
    fprintf(stderr,
"usage: %s --board-ip A.B.C.D --local-port N [options]\n"
"\n"
"required\n"
"  --board-ip A.B.C.D   the board's conf_ip\n"
"  --local-port N       the board's conf_tx_dst_port. This program binds to\n"
"                       it; the board transmits there and nowhere else, so an\n"
"                       ephemeral port will not do.\n"
"\n"
"what to run\n"
"  --speed              throughput mode: paced stream, replies read by a\n"
"                       separate thread. Default is latency mode, one packet\n"
"                       in flight, every reply verified.\n"
"  --size N             one payload size instead of the sweep\n"
"  --jumbo              sweep large sizes up to %d bytes (needs MTU 9000 on both\n"
"                       ends; the design cannot fragment)\n"
"  --soak               repeat until interrupted\n"
"\n"
"tuning\n"
"  --board-port N       port to send to                  (default 1234)\n"
"  --count N            packets per size, latency        (default 16)\n"
"  --duration MS        length of each throughput probe  (default 300)\n"
"  --loss-tol PCT       loss still counted as sustained  (default 0.05)\n"
"  --batch N            packets per sendmmsg call        (default 64, max 256)\n"
"  --rate PCT           pin the rate instead of searching for it\n"
"  --line GBPS          link rate for the ceilings       (default 10)\n"
"  --timeout MS         reply timeout                    (default 500)\n"
"  --gap US             pause between sends, latency     (default 0)\n"
"  --report FILE        write a diagnosis file: every number this run saw,\n"
"                       plus the host settings needed to interpret them\n"
"  --verbose            report every probe, and every loss in latency mode\n"
"\n"
"before running, check this PC against the board's static TX config:\n"
"  ip addr show dev <iface>   must equal conf_tx_dst_ip\n"
"  ip link show dev <iface>   must equal conf_tx_dst_mac\n"
"the board only answers ARP, it never asks, so it cannot learn your MAC.\n",
        me, JUMBO_PAYLOAD);
}

int main(int argc, char **argv)
{
    struct config cfg = {
        .board_ip = NULL, .board_port = 1234, .local_port = 0,
        .count = 16, .timeout_ms = 500, .gap_us = 0, .fixed_size = -1,
        .speed = false, .jumbo = false, .soak = false, .verbose = false,
        .rate_pct = -1, .duration_ms = 300, .loss_tol = 0.05, .batch = 64,
        .line_gbps = 10.0, .report = NULL,
    };

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        #define NEXT() (++i < argc ? argv[i] : (usage(argv[0]), exit(2), ""))
        if      (!strcmp(a, "--board-ip"))   cfg.board_ip   = NEXT();
        else if (!strcmp(a, "--board-port")) cfg.board_port = (uint16_t)atoi(NEXT());
        else if (!strcmp(a, "--local-port")) cfg.local_port = (uint16_t)atoi(NEXT());
        else if (!strcmp(a, "--count"))      cfg.count      = atoi(NEXT());
        else if (!strcmp(a, "--duration"))   cfg.duration_ms = atoi(NEXT());
        else if (!strcmp(a, "--loss-tol"))   cfg.loss_tol   = atof(NEXT());
        else if (!strcmp(a, "--batch"))      cfg.batch      = atoi(NEXT());
        else if (!strcmp(a, "--rate"))       cfg.rate_pct   = atoi(NEXT());
        else if (!strcmp(a, "--line"))       cfg.line_gbps  = atof(NEXT());
        else if (!strcmp(a, "--size"))       cfg.fixed_size = atoi(NEXT());
        else if (!strcmp(a, "--timeout"))    cfg.timeout_ms = atoi(NEXT());
        else if (!strcmp(a, "--gap"))        cfg.gap_us     = atoi(NEXT());
        else if (!strcmp(a, "--report"))     cfg.report     = NEXT();
        else if (!strcmp(a, "--speed"))      cfg.speed      = true;
        else if (!strcmp(a, "--jumbo"))      cfg.jumbo      = true;
        else if (!strcmp(a, "--soak"))       cfg.soak       = true;
        else if (!strcmp(a, "--verbose"))    cfg.verbose    = true;
        else if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(argv[0]); return 0; }
        else { fprintf(stderr, "unknown option '%s'\n\n", a); usage(argv[0]); return 2; }
        #undef NEXT
    }

    if (!cfg.board_ip || cfg.local_port == 0) { usage(argv[0]); return 2; }
    int cap = cfg.jumbo ? JUMBO_PAYLOAD : MTU_PAYLOAD;
    if (cfg.fixed_size > cap) {
        fprintf(stderr, "--size %d exceeds %d; the design cannot fragment%s\n",
                cfg.fixed_size, cap, cfg.jumbo ? "" : " (try --jumbo)");
        return 2;
    }
    if (cfg.rate_pct != -1 && (cfg.rate_pct < 1 || cfg.rate_pct > 100)) {
        fprintf(stderr, "--rate must be 1..100 -- offering more than the wire\n"
                        "can carry measures the NIC's queue, not the board\n");
        return 2;
    }

    struct sockaddr_in board = { .sin_family = AF_INET,
                                 .sin_port = htons(cfg.board_port) };
    if (inet_pton(AF_INET, cfg.board_ip, &board.sin_addr) != 1) {
        fprintf(stderr, "bad --board-ip '%s'\n", cfg.board_ip); return 2;
    }

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) { perror("socket"); return 1; }

    int sockbuf = 8 * 1024 * 1024;
    setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &sockbuf, sizeof sockbuf);
    setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &sockbuf, sizeof sockbuf);

    /* setsockopt does not fail when it cannot honour the size -- the kernel
     * silently clamps to net.core.rmem_max. Read back what was granted. The
     * reader thread means a small buffer is survivable, but it is still worth
     * printing, because it changes how a hostdrop figure should be read. */
    socklen_t bl = sizeof g_rcvbuf;
    getsockopt(sock, SOL_SOCKET, SO_RCVBUF, &g_rcvbuf, &bl);
    bl = sizeof g_sndbuf;
    getsockopt(sock, SOL_SOCKET, SO_SNDBUF, &g_sndbuf, &bl);

    struct sockaddr_in me = { .sin_family = AF_INET,
                              .sin_addr.s_addr = htonl(INADDR_ANY),
                              .sin_port = htons(cfg.local_port) };
    if (bind(sock, (struct sockaddr *)&me, sizeof me) < 0) {
        fprintf(stderr, "bind to port %u: %s\n"
                        "that port must be free -- it is where the board sends\n",
                cfg.local_port, strerror(errno));
        return 1;
    }

    signal(SIGINT, on_sigint);

    static const int sweep_mtu[] = {
        0, 1, 2, 3, 4, 7, 8, 9,
        15, 16, 17, 18, 19, 20,           /* padding boundary; 17 is special */
        23, 24, 25, 31, 32, 33, 39, 40, 41,
        64, 100, 255, 256, 257, 512, 1000, 1024, 1400, MTU_PAYLOAD,
    };
    static const int sweep_jumbo[] = {
        18, 64, 256, 512, 1000, MTU_PAYLOAD, 2048, 4096, 8192, JUMBO_PAYLOAD,
    };
    /* Throughput at 33 sizes takes minutes and says little at the small end
     * that five representative points do not. */
    static const int sweep_speed[] = { 18, 64, 256, 1024, MTU_PAYLOAD };

    const int *sizes; size_t nsizes;
    if (cfg.fixed_size >= 0) { sizes = &cfg.fixed_size; nsizes = 1; }
    else if (cfg.jumbo)      { sizes = sweep_jumbo; nsizes = sizeof sweep_jumbo / sizeof *sweep_jumbo; }
    else if (cfg.speed)      { sizes = sweep_speed; nsizes = sizeof sweep_speed / sizeof *sweep_speed; }
    else                     { sizes = sweep_mtu; nsizes = sizeof sweep_mtu / sizeof *sweep_mtu; }

    char bip[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &board.sin_addr, bip, sizeof bip);

    printf("\n=====================================================================\n");
    printf("  uoe loopback test -- %s mode\n", cfg.speed ? "throughput" : "latency");
    printf("=====================================================================\n");
    printf("  board            %s port %u\n", bip, cfg.board_port);
    printf("  listening on     port %u   (must equal conf_tx_dst_port)\n", cfg.local_port);
    printf("  link rate        %.3g Gbps\n", cfg.line_gbps);
    if (cfg.speed && cfg.rate_pct < 0)
        printf("  rate             searched automatically, %d ms per probe,\n"
               "                   sustained = at most %.3g%% loss\n",
               cfg.duration_ms, cfg.loss_tol);
    else if (cfg.speed)
        printf("  rate             fixed at %d%% of the wire ceiling, %d ms\n",
               cfg.rate_pct, cfg.duration_ms);
    else
        printf("  %d packet(s) per size, %d ms timeout\n", cfg.count, cfg.timeout_ms);
    if (cfg.gap_us) printf("  pacing           %d us between sends\n", cfg.gap_us);
    printf("  socket buffers   rx %d KB, tx %d KB (kernel granted)\n",
           g_rcvbuf / 1024, g_sndbuf / 1024);
    printf("  sizes            %zu", nsizes);
    if (cfg.jumbo) printf("  (jumbo -- needs MTU 9000 end to end)");
    printf("\n\n");

    struct result *res = calloc(nsizes, sizeof *res);
    /* res[] holds only the latest sweep; this remembers every size that failed
     * in any sweep, so --soak and Ctrl-C cannot hide or invent a failure. */
    bool *ever_failed = calloc(nsizes, sizeof *ever_failed);
    if (!res || !ever_failed) { perror("calloc"); return 1; }

    uint32_t seq = 1;
    int failures = 0, sweeps = 0;
    struct result total; memset(&total, 0, sizeof total);
    total.rtt_min = 1e30;

    do {
        if (sweeps == 0) { if (cfg.speed) legend_speed(); else legend_latency(); }
        if (cfg.speed) header_speed(); else header_latency();

        for (size_t i = 0; i < nsizes && !interrupted; i++) {
            int rc;
            if (!cfg.speed)
                rc = latency_size(sock, &board, &cfg, sizes[i], &seq, &res[i]);
            else if (cfg.rate_pct < 0)
                rc = auto_speed_size(sock, &board, &cfg, sizes[i], &seq, &res[i]);
            else
                rc = speed_size(sock, &board, &cfg, sizes[i], cfg.rate_pct, &seq, &res[i]);
            if (rc < 0) { free(res); free(ever_failed); return 1; }

            if (cfg.speed) row_speed(&res[i]); else row_latency(&res[i]);
            fflush(stdout);

            if (!res[i].ok) { failures++; ever_failed[i] = true; }
            total.sent       += res[i].sent;       total.received  += res[i].received;
            total.lost       += res[i].lost;       total.corrupt   += res[i].corrupt;
            total.wrong_len  += res[i].wrong_len;  total.wrong_src += res[i].wrong_src;
            total.dup        += res[i].dup;        total.reordered += res[i].reordered;
            total.host_drops += res[i].host_drops; total.tx_fail   += res[i].tx_fail;
            if (res[i].rtt_min > 0 && res[i].rtt_min < total.rtt_min)
                total.rtt_min = res[i].rtt_min;
            if (res[i].rtt_max > total.rtt_max) total.rtt_max = res[i].rtt_max;
            if (res[i].achieved_gbps > total.achieved_gbps)
                total.achieved_gbps = res[i].achieved_gbps;
        }
        sweeps++;
        if (cfg.soak && !interrupted)
            printf("  --- sweep %d complete, %d failing result(s) so far ---\n",
                   sweeps, failures);
    } while (cfg.soak && !interrupted);

    printf("\n---------------------------------------------------------------------\n");
    printf("  totals   sent %ld   received %ld\n", total.sent, total.received);
    printf("           lost %ld   corrupt %ld   wrong length %ld   wrong source %ld\n",
           total.lost, total.corrupt, total.wrong_len, total.wrong_src);
    printf("           duplicated %ld   reordered %ld\n", total.dup, total.reordered);
    if (total.host_drops)
        printf("           %ld discarded by this PC's kernel, excluded from the search\n",
               total.host_drops);
    if (total.tx_fail)
        printf("           %ld never left this PC (ENOBUFS / short send), not counted as sent\n",
               total.tx_fail);
    if (total.rtt_min < 1e29)
        printf("  rtt      %.3f .. %.3f ms\n", total.rtt_min, total.rtt_max);
    if (cfg.speed)
        printf("  best achieved goodput %.3f Gbps\n", total.achieved_gbps);

    if (cfg.speed) {
        /* The headline: one line per size saying what it sustained, and how
         * that compares with the design's own figure. The table above is the
         * working; this is the answer. */
        printf("\n  sustained goodput\n");
        for (size_t i = 0; i < nsizes; i++) {
            const struct result *r = &res[i];
            int frame = r->size + UOE_HEADERS;
            if (frame < ETH_MIN_FRAME) frame = ETH_MIN_FRAME;
            if (!r->ok) {
                printf("    %5d byte payload (%d byte frame):  nothing sustained"
                       " -- lost packets at every rate tried\n", r->size, frame);
                /* Say this for failing sizes too -- a probe that ran a tenth
                 * of the requested time is the first thing to question when a
                 * size fails, not a footnote for the ones that passed. */
                if (r->burst_capped)
                    printf("            ^ probe ran %.0f ms, not the %d ms "
                           "asked for: %d packets is the cap. A short burst\n"
                           "              can pass where sustained load would "
                           "not.\n", r->elapsed_ms, cfg.duration_ms, MAX_BURST);
                continue;
            }
            printf("    %5d byte payload (%d byte frame):  %.3f Gbps"
                   "  (%.1f%% of the %.3f Gbps design figure, %.3f Mpps)\n",
                   r->size, frame, r->achieved_gbps,
                   r->ceil_design_gbps > 0
                       ? 100.0 * r->achieved_gbps / r->ceil_design_gbps : 0.0,
                   r->ceil_design_gbps, r->achieved_mpps);
            if (r->peak_gbps > r->achieved_gbps * 1.05)
                printf("            ^ a probe reached %.3f Gbps before the "
                       "search settled here. The search is sensitive to one\n"
                       "              noisy probe; treat %.3f as the floor.\n",
                       r->peak_gbps, r->peak_gbps);
            if (r->offered_gbps > 0 && r->achieved_gbps < 0.8 * r->offered_gbps) {
                printf("            ^ HOST-LIMITED: offered %.3f Gbps, sent only"
                       " %.3f. This PC was the ceiling, so the figure above is\n"
                       "              a FLOOR for the board, not a measurement of it.\n",
                       r->offered_gbps, r->achieved_gbps);
                if (r->tx_fail)
                    printf("              %ld packet(s) never left this PC "
                           "(ENOBUFS / short send). Try a larger --batch.\n", r->tx_fail);
                else
                    printf("              The pacing loop could not keep up. "
                           "Try a larger --batch.\n");
            }
            if (r->host_drops > 0)
                printf("            ^ this PC's kernel discarded %ld reply(s) "
                       "(/proc/net/udp, softnet_stat); not board loss\n", r->host_drops);
            if (r->burst_capped)
                printf("            ^ probe ran %.0f ms, not the %d ms asked "
                       "for: %d packets is the cap. A short burst can pass\n"
                       "              where sustained load would not.\n",
                       r->elapsed_ms, cfg.duration_ms, MAX_BURST);

        }
    }

    if (interrupted) printf("\n  interrupted\n");

    if (failures) {
        if (sweeps > 1)
            printf("\n  FAIL -- %d failing result(s) over %d sweeps:\n", failures, sweeps);
        else
            printf("\n  FAIL -- %d size(s) did not pass:\n", failures);
        for (size_t i = 0; i < nsizes; i++) {
            if (!ever_failed[i]) continue;
            printf("    %5d bytes:", res[i].size);
            if (res[i].ok) { printf("  failed in an earlier sweep, passed in the last\n"); continue; }
            if (cfg.speed && res[i].rate_pct == 0)
                printf("  no rate sustained -- lost packets even at the lowest probe");
            if (res[i].lost)      printf("  %ld lost", res[i].lost);
            if (res[i].host_drops) printf("  (%ld of them this PC's kernel)", res[i].host_drops);
            if (res[i].corrupt)   printf("  %ld corrupt", res[i].corrupt);
            if (res[i].wrong_len) printf("  %ld wrong length", res[i].wrong_len);
            if (res[i].wrong_src) printf("  %ld from the wrong source", res[i].wrong_src);
            printf("\n");
        }
        if (cfg.speed)
            printf("\n  loss under --speed may be the loopback, not the datapath:\n"
                   "  rx_udp has no tready, so tx_udp's backpressure is discarded.\n"
                   "  Re-run the same size in latency mode before blaming the design.\n");
    } else {
        printf("\n  PASS -- every size correct\n");
    }
    printf("\n");

    if (cfg.report)
        write_report(&cfg, res, nsizes, &total, failures, sweeps);

    free(res);
    free(ever_failed);
    close(sock);
    return failures ? 1 : 0;
}
