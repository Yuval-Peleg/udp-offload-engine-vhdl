/*
 * udp_echo -- a fast UDP reflector, for checking uoe_loopback_test itself.
 *
 * The board is the thing under test, so the test has to be trusted first. Run
 * this on a second PC (or on localhost) and point uoe_loopback_test at it: a
 * clean sweep proves the addressing and the tool (and, from a second PC, the
 * cabling), leaving the board as the main variable when something later fails.
 *
 * It uses recvmmsg/sendmmsg for the same reason the test does. A reflector
 * built on one recvfrom+sendto per packet tops out well below line rate, and
 * then a throughput run measures the reflector rather than anything else --
 * which is exactly the trap a naive echo script falls into.
 *
 * It mimics the board's addressing: replies go to a FIXED destination
 * (--reply-to host:port) rather than back to the sender's ephemeral port,
 * because that is what the UOE does and the test is built around it.
 *
 *      make udp_echo
 *      ./udp_echo --port 1234 --reply-to 127.0.0.1:4660
 */

#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define BATCH   64
#define MAXPKT  9100

static volatile sig_atomic_t stop = 0;
static void on_int(int s) { (void)s; stop = 1; }

int main(int argc, char **argv)
{
    uint16_t listen_port = 1234;
    const char *reply_to = NULL;
    long drop_every = 0;          /* fault injection: drop 1 in N */

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--port") && i + 1 < argc)
            listen_port = (uint16_t)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--reply-to") && i + 1 < argc)
            reply_to = argv[++i];
        else if (!strcmp(argv[i], "--drop-every") && i + 1 < argc)
            drop_every = atol(argv[++i]);
        else {
            fprintf(stderr,
"usage: %s --port N --reply-to HOST:PORT [--drop-every N]\n"
"\n"
"  --port N            UDP port to listen on            (default 1234)\n"
"  --reply-to HOST:PORT where to send replies. Fixed, like the board's\n"
"                      conf_tx_dst_ip / conf_tx_dst_port -- NOT the sender's\n"
"                      source port.\n"
"  --drop-every N      drop one packet in N, to prove the test detects loss\n",
                    argv[0]);
            return 2;
        }
    }
    if (!reply_to) { fprintf(stderr, "--reply-to is required\n"); return 2; }

    char host[128]; int rport = 0;
    if (sscanf(reply_to, "%127[^:]:%d", host, &rport) != 2) {
        fprintf(stderr, "--reply-to must be HOST:PORT\n"); return 2;
    }
    struct sockaddr_in dst = { .sin_family = AF_INET,
                               .sin_port = htons((uint16_t)rport) };
    if (inet_pton(AF_INET, host, &dst.sin_addr) != 1) {
        fprintf(stderr, "bad host '%s'\n", host); return 2;
    }

    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) { perror("socket"); return 1; }
    int buf = 16 * 1024 * 1024;
    setsockopt(s, SOL_SOCKET, SO_RCVBUF, &buf, sizeof buf);
    setsockopt(s, SOL_SOCKET, SO_SNDBUF, &buf, sizeof buf);

    struct sockaddr_in me = { .sin_family = AF_INET,
                              .sin_addr.s_addr = htonl(INADDR_ANY),
                              .sin_port = htons(listen_port) };
    if (bind(s, (struct sockaddr *)&me, sizeof me) < 0) {
        fprintf(stderr, "bind %u: %s\n", listen_port, strerror(errno));
        return 1;
    }

    static uint8_t data[BATCH][MAXPKT];
    struct mmsghdr rm[BATCH], sm[BATCH];
    struct iovec   riov[BATCH], siov[BATCH];

    /* Zero these before use. msghdr has msg_control / msg_controllen /
     * msg_flags as well as the fields set below, and on the stack they hold
     * garbage -- the kernel then tries to read ancillary data from a junk
     * pointer and every sendmmsg fails with EFAULT. */
    memset(rm, 0, sizeof rm);
    memset(sm, 0, sizeof sm);

    for (int i = 0; i < BATCH; i++) {
        riov[i].iov_base = data[i]; riov[i].iov_len = MAXPKT;
        rm[i].msg_hdr.msg_iov = &riov[i]; rm[i].msg_hdr.msg_iovlen = 1;
        rm[i].msg_hdr.msg_name = NULL;    rm[i].msg_hdr.msg_namelen = 0;
        siov[i].iov_base = data[i];
        sm[i].msg_hdr.msg_iov = &siov[i]; sm[i].msg_hdr.msg_iovlen = 1;
        sm[i].msg_hdr.msg_name = &dst;    sm[i].msg_hdr.msg_namelen = sizeof dst;
    }

    signal(SIGINT, on_int);
    printf("udp_echo: listening on %u, replying to %s:%d%s\n",
           listen_port, host, rport,
           drop_every ? " (dropping some, deliberately)" : "");

    unsigned long long in = 0, out = 0, dropped = 0;

    while (!stop) {
        /* MSG_WAITFORONE is not optional: without it recvmmsg blocks until it
         * has collected all BATCH messages, so a lone packet is never
         * answered and the echo looks dead. */
        int n = recvmmsg(s, rm, BATCH, MSG_WAITFORONE, NULL);
        if (n <= 0) { if (errno == EINTR) continue; break; }

        int k = 0;
        for (int i = 0; i < n; i++) {
            in++;
            if (rm[i].msg_len == 0) continue;      /* nothing to reflect */
            if (drop_every && (in % (unsigned long long)drop_every) == 0) {
                dropped++;
                continue;
            }
            /* reflect in place: data[i] already holds the payload */
            siov[k].iov_base = data[i];
            siov[k].iov_len  = rm[i].msg_len;
            sm[k].msg_hdr.msg_iov = &siov[k];
            k++;
        }
        if (k > 0) {
            int sent = sendmmsg(s, sm, (unsigned)k, 0);
            if (sent > 0) out += (unsigned long long)sent;
        }
    }

    printf("\nudp_echo: %llu in, %llu out", in, out);
    if (dropped) printf(", %llu deliberately dropped", dropped);
    printf("\n");
    close(s);
    return 0;
}
