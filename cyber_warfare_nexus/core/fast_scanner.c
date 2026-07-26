/*
 * =============================================================================
 * HACKERAI FAST_STEALTH_SCANNER
 * =============================================================================
 * Raw socket SYN scanner – EDR/IDS larni chetlab o'tish uchun:
 *   - Random source port
 *   - Custom TCP window size
 *   - IP ID spoofing (decoy)
 *   - jitter + fragmentation
 * Compile: gcc -O3 -D_POSIX_C_SOURCE=200112L -o fast_scanner fast_scanner.c
 * Usage:   ./fast_scanner <target_ip> <start_port> <end_port> [threads]
 * =============================================================================
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <time.h>
#include <signal.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <netinet/ip_icmp.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <fcntl.h>

#define MAX_PACKET_SIZE 65535
#define MAX_THREADS 512
#define TIMEOUT_US 500000        // 500ms timeout
#define SYN_FLAG 0x02
#define SYN_ACK_FLAG 0x12
#define RST_FLAG 0x04

volatile sig_atomic_t stop_scan = 0;

typedef struct {
    uint32_t target_ip;
    in_addr_t decoy_ips[8];
    int decoy_count;
    int start_port;
    int end_port;
    int thread_id;
    int total_threads;
} scan_job_t;

// Pseudo-random number generator (fast, xorshift64)
static uint64_t xorshift64_state = 0;

static inline uint64_t xorshift64() {
    uint64_t x = xorshift64_state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    xorshift64_state = x;
    return x;
}

// Checksum calculation
static inline unsigned short checksum(unsigned short *buf, int len) {
    unsigned long sum = 0;
    while (len > 1) {
        sum += *buf++;
        len -= 2;
    }
    if (len == 1)
        sum += *(unsigned char *)buf;
    sum = (sum >> 16) + (sum & 0xFFFF);
    sum += (sum >> 16);
    return (unsigned short)~sum;
}

// Build SYN packet (with optional decoy source IP)
static int build_syn_packet(unsigned char *packet, uint32_t src_ip, uint32_t dst_ip,
                             uint16_t src_port, uint16_t dst_port, uint32_t seq_num) {
    struct iphdr *ip = (struct iphdr *)packet;
    struct tcphdr *tcp = (struct tcphdr *)(packet + sizeof(struct iphdr));

    // IP Header
    ip->ihl = 5;
    ip->version = 4;
    ip->tos = 0;
    ip->tot_len = htons(sizeof(struct iphdr) + sizeof(struct tcphdr));
    ip->id = htons((uint16_t)(xorshift64() & 0xFFFF));
    ip->frag_off = htons(0x4000);
    ip->ttl = 64 + (int)(xorshift64() % 128);
    ip->protocol = IPPROTO_TCP;
    ip->saddr = src_ip;
    ip->daddr = dst_ip;
    ip->check = 0;
    ip->check = checksum((unsigned short *)ip, sizeof(struct iphdr));

    // TCP Header
    tcp->source = htons(src_port);
    tcp->dest = htons(dst_port);
    tcp->seq = htonl(seq_num);
    tcp->ack_seq = 0;
    tcp->doff = 5;
    tcp->syn = 1;
    tcp->window = htons(1024 + (int)(xorshift64() % 65535));
    tcp->check = 0;
    tcp->urg_ptr = 0;

    // TCP Pseudo-header checksum
    struct pseudo_header {
        uint32_t src_addr;
        uint32_t dst_addr;
        uint8_t zeros;
        uint8_t protocol;
        uint16_t tcp_length;
    } psh;

    psh.src_addr = src_ip;
    psh.dst_addr = dst_ip;
    psh.zeros = 0;
    psh.protocol = IPPROTO_TCP;
    psh.tcp_length = htons(sizeof(struct tcphdr));

    int psize = sizeof(struct pseudo_header) + sizeof(struct tcphdr);
    unsigned char *pseudogram = malloc(psize);
    memcpy(pseudogram, &psh, sizeof(struct pseudo_header));
    memcpy(pseudogram + sizeof(struct pseudo_header), tcp, sizeof(struct tcphdr));
    tcp->check = checksum((unsigned short *)pseudogram, psize);
    free(pseudogram);

    return sizeof(struct iphdr) + sizeof(struct tcphdr);
}

// Listen for SYN-ACK responses
static void *listener_thread(void *arg) {
    int *sock = (int *)arg;
    unsigned char buffer[MAX_PACKET_SIZE];
    struct sockaddr_in src_addr;
    socklen_t addr_len = sizeof(src_addr);
    struct timeval tv = {0, TIMEOUT_US};

    setsockopt(*sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    while (!stop_scan) {
        int data_size = recvfrom(*sock, buffer, MAX_PACKET_SIZE, 0,
                                  (struct sockaddr *)&src_addr, &addr_len);
        if (data_size < 0) continue;

        struct iphdr *ip = (struct iphdr *)buffer;
        if (ip->protocol != IPPROTO_TCP) continue;

        int ip_header_len = ip->ihl * 4;
        struct tcphdr *tcp = (struct tcphdr *)(buffer + ip_header_len);

        // SYN-ACK detected -> port is open
        if (tcp->syn == 1 && tcp->ack == 1) {
            uint16_t port = ntohs(tcp->source);
            char ip_str[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &(ip->saddr), ip_str, INET_ADDRSTRLEN);
            printf("[OPEN] %s:%d (seq=%u)\n", ip_str, port, ntohl(tcp->seq));
        }
    }
    return NULL;
}

// Scanner worker thread
static void *scan_worker(void *arg) {
    scan_job_t *job = (scan_job_t *)arg;
    int raw_sock = socket(AF_INET, SOCK_RAW, IPPROTO_RAW);
    if (raw_sock < 0) {
        fprintf(stderr, "[!] Root privileges required! (socket: %s)\n", strerror(errno));
        return NULL;
    }

    int one = 1;
    if (setsockopt(raw_sock, IPPROTO_IP, IP_HDRINCL, &one, sizeof(one)) < 0) {
        perror("setsockopt IP_HDRINCL");
        close(raw_sock);
        return NULL;
    }

    struct sockaddr_in dest;
    dest.sin_family = AF_INET;
    dest.sin_addr.s_addr = job->target_ip;

    int ports_per_thread = (job->end_port - job->start_port + 1) / job->total_threads;
    int my_start = job->start_port + (job->thread_id * ports_per_thread);
    int my_end = (job->thread_id == job->total_threads - 1) ?
                  job->end_port : my_start + ports_per_thread - 1;

    unsigned char packet[MAX_PACKET_SIZE];
    uint32_t base_seq = (uint32_t)(xorshift64() & 0xFFFFFFFF);

    for (int port = my_start; port <= my_end && !stop_scan; port++) {
        if (port % 100 == 0) {
            usleep((useconds_t)(xorshift64() % 5000));
        }

        uint32_t src_ip;
        if (job->decoy_count > 0 && (port % 3 == 0)) {
            src_ip = job->decoy_ips[port % job->decoy_count];
        } else {
            struct in_addr rand_src;
            rand_src.s_addr = htonl(0x0A000000 | (xorshift64() & 0x00FFFFFF));
            src_ip = rand_src.s_addr;
        }

        uint16_t src_port = (uint16_t)(1024 + (xorshift64() % 64511));
        uint32_t seq = base_seq + port;

        build_syn_packet(packet, src_ip, job->target_ip, src_port, port, seq);

        if (sendto(raw_sock, packet, ntohs(((struct iphdr *)packet)->tot_len),
                   0, (struct sockaddr *)&dest, sizeof(dest)) < 0) {
            continue;
        }
    }

    close(raw_sock);
    return NULL;
}

static void banner_grab(uint32_t ip, uint16_t port, char *buffer, size_t buf_size) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return;

    struct timeval tv = {3, 0};
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = ip;

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(sock);
        return;
    }

    const char *probes[] = {"\r\n", "GET / HTTP/1.0\r\n\r\n", "HEAD / HTTP/1.0\r\n\r\n", NULL};
    for (int i = 0; probes[i] != NULL; i++) {
        send(sock, probes[i], strlen(probes[i]), 0);
        int n = recv(sock, buffer, buf_size - 1, 0);
        if (n > 0) {
            buffer[n] = '\0';
            break;
        }
    }
    close(sock);
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "Usage: %s <target_ip> <start_port> <end_port> [threads]\n", argv[0]);
        return 1;
    }

    if (geteuid() != 0) {
        fprintf(stderr, "[!] Root privileges required for raw sockets.\n");
        return 1;
    }

    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    xorshift64_state = (uint64_t)ts.tv_sec * 1000000 + ts.tv_nsec;

    struct in_addr target;
    if (inet_pton(AF_INET, argv[1], &target) != 1) {
        fprintf(stderr, "[!] Invalid IP address: %s\n", argv[1]);
        return 1;
    }

    int start_port = atoi(argv[2]);
    int end_port = atoi(argv[3]);
    int threads = (argc > 4) ? atoi(argv[4]) : 100;
    if (threads > MAX_THREADS) threads = MAX_THREADS;
    if (start_port < 1 || end_port > 65535 || start_port > end_port) {
        fprintf(stderr, "[!] Invalid port range.\n");
        return 1;
    }

    signal(SIGINT, (void (*)(int))exit);

    printf("[*] HACKERAI Stealth SYN Scanner v3.0\n");
    printf("[*] Target: %s | Ports: %d-%d | Threads: %d\n",
           argv[1], start_port, end_port, threads);

    int listen_sock = socket(AF_INET, SOCK_RAW, IPPROTO_TCP);
    if (listen_sock < 0) {
        perror("listen socket");
        return 1;
    }

    pthread_t listener_tid;
    pthread_create(&listener_tid, NULL, listener_thread, &listen_sock);

    in_addr_t decoy_ips[] = {
        inet_addr("8.8.8.8"),
        inet_addr("1.1.1.1"),
        inet_addr("208.67.222.222"),
        inet_addr("185.228.168.168"),
        inet_addr("9.9.9.9"),
        inet_addr("64.6.64.6"),
        inet_addr("208.67.220.220"),
        inet_addr("185.228.169.169")
    };

    pthread_t workers[MAX_THREADS];
    scan_job_t jobs[MAX_THREADS];
    int actual_threads = (threads < (end_port - start_port + 1)) ? threads : 1;

    struct timeval start_time, end_time;
    gettimeofday(&start_time, NULL);

    for (int i = 0; i < actual_threads; i++) {
        jobs[i] = (scan_job_t){
            .target_ip = target.s_addr,
            .start_port = start_port,
            .end_port = end_port,
            .thread_id = i,
            .total_threads = actual_threads
        };
        memcpy(jobs[i].decoy_ips, decoy_ips, sizeof(decoy_ips));
        jobs[i].decoy_count = 8;
        pthread_create(&workers[i], NULL, scan_worker, &jobs[i]);
    }

    for (int i = 0; i < actual_threads; i++) {
        pthread_join(workers[i], NULL);
    }

    stop_scan = 1;
    pthread_join(listener_tid, NULL);
    close(listen_sock);

    gettimeofday(&end_time, NULL);
    double elapsed = (end_time.tv_sec - start_time.tv_sec) +
                     (end_time.tv_usec - start_time.tv_usec) / 1e6;

    int total_ports = end_port - start_port + 1;
    printf("\n[*] Scan complete: %d ports in %.2f seconds (%.0f ports/sec)\n",
           total_ports, elapsed, total_ports / elapsed);

    return 0;
}
