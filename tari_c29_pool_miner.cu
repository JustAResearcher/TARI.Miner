// tari_c29_pool_miner.cu - LuckyPool-compatible Tari C29 pool miner.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This is intentionally small and explicit: it wraps the verified Tari C29
// proof code and the reference CUDA Cuckaroo29 trimmer with the LuckyPool
// JSON-RPC dialect captured from lolMiner 1.98.

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <thread>
#include <mutex>
#include <atomic>
#include <chrono>
#include <algorithm>
#include <future>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "Ws2_32.lib")
using socket_t = SOCKET;
static const socket_t INVALID_SOCK = INVALID_SOCKET;
#else
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>
#include <errno.h>
extern "C" int close(int);
extern "C" int gethostname(char *, size_t);
using socket_t = int;
static const socket_t INVALID_SOCK = -1;
#endif

// --- MSVC host-compiler shims for the reference solver's GNU-isms ---
#if defined(_MSC_VER)
#define __builtin_prefetch(...) ((void)0)
#ifndef PORTABLE_ENDIAN_H__
#define PORTABLE_ENDIAN_H__
#include <stdlib.h>
#define htole16(x) (x)
#define htole32(x) (x)
#define htole64(x) (x)
#define le16toh(x) (x)
#define le32toh(x) (x)
#define le64toh(x) (x)
#define htobe16(x) _byteswap_ushort(x)
#define htobe32(x) _byteswap_ulong(x)
#define htobe64(x) _byteswap_uint64(x)
#define be16toh(x) _byteswap_ushort(x)
#define be32toh(x) _byteswap_ulong(x)
#define be64toh(x) _byteswap_uint64(x)
#endif
#endif

#define SQUASH_OUTPUT 1
#ifndef TARI_C29_MAX_PIPELINE
#define TARI_C29_MAX_PIPELINE 5
#endif
#ifndef SOLVER_PRELAUNCH_NEXT
#define SOLVER_PRELAUNCH_NEXT 0
#endif
#define main reference_mean_main_unused
#include "mean_c29.cu"
#undef main

#include "tari_c29.h"
#include "version.h"

static double now_sec() {
    using namespace std::chrono;
    return duration_cast<duration<double>>(steady_clock::now().time_since_epoch()).count();
}

static void close_socket(socket_t s) {
    if (s == INVALID_SOCK) return;
#if defined(_WIN32)
    closesocket(s);
#else
    close(s);
#endif
}

static void shutdown_socket(socket_t s) {
    if (s == INVALID_SOCK) return;
#if defined(_WIN32)
    shutdown(s, SD_BOTH);
#else
    shutdown(s, SHUT_RDWR);
#endif
}

static int socket_init() {
#if defined(_WIN32)
    WSADATA wsa;
    return WSAStartup(MAKEWORD(2, 2), &wsa);
#else
    return 0;
#endif
}

static void socket_cleanup() {
#if defined(_WIN32)
    WSACleanup();
#endif
}

static std::string json_escape(const std::string &s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (char c : s) {
        if (c == '"' || c == '\\') {
            out.push_back('\\');
            out.push_back(c);
        } else if ((unsigned char)c < 0x20) {
            char buf[7];
            snprintf(buf, sizeof(buf), "\\u%04x", (unsigned char)c);
            out += buf;
        } else {
            out.push_back(c);
        }
    }
    return out;
}

static bool split_host_port(const std::string &pool, std::string &host, std::string &port) {
    size_t p = pool.rfind(':');
    if (p == std::string::npos || p == 0 || p + 1 >= pool.size()) return false;
    host = pool.substr(0, p);
    port = pool.substr(p + 1);
    return true;
}

static socket_t connect_tcp(const std::string &host, const std::string &port) {
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo *res = nullptr;
    if (getaddrinfo(host.c_str(), port.c_str(), &hints, &res) != 0) return INVALID_SOCK;
    socket_t sock = INVALID_SOCK;
    for (addrinfo *rp = res; rp; rp = rp->ai_next) {
        sock = (socket_t)socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (sock == INVALID_SOCK) continue;
        if (connect(sock, rp->ai_addr, (int)rp->ai_addrlen) == 0) break;
        close_socket(sock);
        sock = INVALID_SOCK;
    }
    freeaddrinfo(res);
    return sock;
}

static bool send_all(socket_t sock, const std::string &s) {
    const char *p = s.data();
    size_t left = s.size();
    while (left) {
        int n = send(sock, p, (int)left, 0);
        if (n <= 0) return false;
        p += n;
        left -= (size_t)n;
    }
    return true;
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static bool parse_hex_bytes(const std::string &hex, uint8_t *out, size_t out_len) {
    if (hex.size() != out_len * 2) return false;
    for (size_t i = 0; i < out_len; ++i) {
        int hi = hexval(hex[2 * i]);
        int lo = hexval(hex[2 * i + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = (uint8_t)((hi << 4) | lo);
    }
    return true;
}

static std::string hex_bytes(const uint8_t *p, size_t n) {
    static const char hexdig[] = "0123456789abcdef";
    std::string out;
    out.resize(n * 2);
    for (size_t i = 0; i < n; ++i) {
        out[2 * i] = hexdig[p[i] >> 4];
        out[2 * i + 1] = hexdig[p[i] & 15];
    }
    return out;
}

static bool json_get_string_from(const std::string &line, const char *key, std::string &out, size_t start = 0) {
    std::string pat = std::string("\"") + key + "\":\"";
    size_t p = line.find(pat, start);
    if (p == std::string::npos) return false;
    p += pat.size();
    std::string val;
    bool esc = false;
    for (; p < line.size(); ++p) {
        char c = line[p];
        if (esc) {
            val.push_back(c);
            esc = false;
        } else if (c == '\\') {
            esc = true;
        } else if (c == '"') {
            out = val;
            return true;
        } else {
            val.push_back(c);
        }
    }
    return false;
}

static bool json_get_uint_from(const std::string &line, const char *key, uint64_t &out, size_t start = 0) {
    std::string pat = std::string("\"") + key + "\":";
    size_t p = line.find(pat, start);
    if (p == std::string::npos) return false;
    p += pat.size();
    char *end = nullptr;
    out = strtoull(line.c_str() + p, &end, 10);
    return end && end != line.c_str() + p;
}

static uint64_t target_hex_to_diff(const std::string &target_hex) {
    if (target_hex.size() != 16) return 1;
    uint8_t b[8];
    if (!parse_hex_bytes(target_hex, b, sizeof(b))) return 1;
    uint64_t target = 0;
    for (int i = 7; i >= 0; --i) target = (target << 8) | b[i]; // pool target is little-endian
    if (target == 0) return ~0ULL;
    uint64_t diff = (~0ULL) / target;
    return diff ? diff : 1;
}

static uint64_t nonce_prefix_base(const std::string &xn_hex, uint64_t *counter_mask) {
    size_t nbytes = xn_hex.size() / 2;
    if ((xn_hex.size() % 2) || nbytes > 8) {
        *counter_mask = ~0ULL;
        return 0;
    }
    uint64_t prefix = 0;
    for (size_t i = 0; i < nbytes; ++i) {
        int hi = hexval(xn_hex[2 * i]);
        int lo = hexval(xn_hex[2 * i + 1]);
        if (hi < 0 || lo < 0) {
            *counter_mask = ~0ULL;
            return 0;
        }
        prefix = (prefix << 8) | (uint64_t)((hi << 4) | lo);
    }
    int free_bits = (int)(64 - 8 * nbytes);
    uint64_t base = free_bits == 64 ? 0 : (prefix << free_bits);
    *counter_mask = free_bits == 64 ? ~0ULL : ((1ULL << free_bits) - 1ULL);
    return base;
}

static std::string nonce_hex_be(uint64_t nonce) {
    uint8_t b[8];
    for (int i = 0; i < 8; ++i) b[i] = (uint8_t)(nonce >> (56 - 8 * i));
    return hex_bytes(b, sizeof(b));
}

struct Job {
    std::string job_id;
    std::string blob_hex;
    std::string target_hex;
    std::string xn_hex;
    uint8_t mining_hash[32]{};
    uint64_t target_diff = 1;
    uint64_t height = 0;
    uint64_t seq = 0;
};

static bool parse_job_line(const std::string &line, Job &current, Job &out) {
    size_t start = line.find("\"job\":");
    if (start == std::string::npos) start = line.find("\"params\":");
    if (start == std::string::npos) return false;

    Job j = current;
    std::string blob, job_id, target, xn;
    if (!json_get_string_from(line, "blob", blob, start)) return false;
    if (!json_get_string_from(line, "job_id", job_id, start)) return false;
    if (!json_get_string_from(line, "target", target, start)) target = j.target_hex;
    if (json_get_string_from(line, "xn", xn, start)) j.xn_hex = xn;
    uint64_t height = 0;
    if (json_get_uint_from(line, "height", height, start)) j.height = height;

    if (!parse_hex_bytes(blob, j.mining_hash, 32)) return false;
    j.blob_hex = blob;
    j.job_id = job_id;
    j.target_hex = target;
    j.target_diff = target_hex_to_diff(target);
    j.seq = current.seq + 1;
    out = j;
    return true;
}

class PoolClient {
public:
    bool connect_login(const std::string &pool, const std::string &login, const std::string &pass) {
        std::string host, port;
        if (!split_host_port(pool, host, port)) {
            fprintf(stderr, "bad --pool, expected host:port\n");
            return false;
        }
        sock_ = connect_tcp(host, port);
        if (sock_ == INVALID_SOCK) return false;
        running_.store(true);
        reader_ = std::thread([this]() { read_loop(); });

        std::string req =
            "{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"login\",\"params\":{\"agent\":\"tari-miner/" TARI_MINER_VERSION "\","
            "\"login\":\"" + json_escape(login) + "\",\"pass\":\"" + json_escape(pass) + "\"}}\n";
        return send_line(req);
    }

    void stop() {
        running_.store(false);
        shutdown_socket(sock_);
        close_socket(sock_);
        sock_ = INVALID_SOCK;
        if (reader_.joinable()) reader_.join();
    }

    ~PoolClient() {
        stop();
    }

    bool alive() const {
        return running_.load();
    }

    bool wait_for_job(Job &job, int timeout_ms) {
        double end = now_sec() + timeout_ms / 1000.0;
        uint64_t last = 0;
        while (now_sec() < end) {
            {
                std::lock_guard<std::mutex> lk(mu_);
                if (job_.seq != 0 && job_.seq != last) {
                    job = job_;
                    return true;
                }
                last = job_.seq;
            }
            if (!alive()) return false;
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
        return false;
    }

    Job current_job() {
        std::lock_guard<std::mutex> lk(mu_);
        return job_;
    }

    bool submit_share(const Job &job, uint64_t nonce, const uint32_t edges[TARI_C29_PROOFSIZE]) {
        std::string id;
        {
            std::lock_guard<std::mutex> lk(mu_);
            id = login_id_;
        }
        if (id.empty()) return false;

        uint8_t packed[TARI_C29_PACKED_BYTES];
        uint8_t result[32];
        tari_c29_pack(edges, packed);
        blake2b(result, 32, packed, TARI_C29_PACKED_BYTES, nullptr, 0);

        std::string req = "{\"id\":4,\"jsonrpc\":\"2.0\",\"method\":\"submit\",\"params\":{\"id\":\"" +
            json_escape(id) + "\",\"job_id\":\"" + json_escape(job.job_id) + "\",\"nonce\":\"" +
            nonce_hex_be(nonce) + "\",\"pow\":[";
        for (int i = 0; i < TARI_C29_PROOFSIZE; ++i) {
            if (i) req.push_back(',');
            char buf[32];
            snprintf(buf, sizeof(buf), "%u", edges[i]);
            req += buf;
        }
        req += "],\"result\":\"" + hex_bytes(result, sizeof(result)) + "\"}}\n";
        return send_line(req);
    }

    uint64_t accepted() const { return accepted_.load(); }
    uint64_t rejected() const { return rejected_.load(); }

private:
    bool send_line(const std::string &line) {
        std::lock_guard<std::mutex> lk(send_mu_);
        if (sock_ == INVALID_SOCK) return false;
        return send_all(sock_, line);
    }

    void read_loop() {
        std::string buf;
        char tmp[4096];
        while (running_.load()) {
            int n = recv(sock_, tmp, sizeof(tmp), 0);
            if (n <= 0) break;
            buf.append(tmp, tmp + n);
            size_t pos;
            while ((pos = buf.find('\n')) != std::string::npos) {
                std::string line = buf.substr(0, pos);
                if (!line.empty() && line.back() == '\r') line.pop_back();
                buf.erase(0, pos + 1);
                handle_line(line);
            }
        }
        running_.store(false);
    }

    void handle_line(const std::string &line) {
        if (line.find("\"result\":true") != std::string::npos) {
            accepted_.fetch_add(1);
            printf("share accepted (%llu total)\n", (unsigned long long)accepted_.load());
            return;
        }
        if (line.find("\"error\"") != std::string::npos && line.find("\"error\":null") == std::string::npos) {
            rejected_.fetch_add(1);
            printf("pool error/reject: %s\n", line.c_str());
            return;
        }

        std::lock_guard<std::mutex> lk(mu_);
        size_t result_pos = line.find("\"result\":");
        std::string id;
        if (result_pos != std::string::npos && json_get_string_from(line, "id", id, result_pos)) {
            login_id_ = id;
        }

        Job parsed;
        if (parse_job_line(line, job_, parsed)) {
            job_ = parsed;
            printf("new job height=%llu id=%s diff=%llu xn=%s\n",
                   (unsigned long long)job_.height, job_.job_id.c_str(),
                   (unsigned long long)job_.target_diff, job_.xn_hex.c_str());
        }
    }

    socket_t sock_ = INVALID_SOCK;
    std::thread reader_;
    mutable std::mutex mu_;
    std::mutex send_mu_;
    Job job_;
    std::string login_id_;
    std::atomic<bool> running_{false};
    std::atomic<uint64_t> accepted_{0};
    std::atomic<uint64_t> rejected_{0};
};

struct Options {
    std::string pool = "taric29-ca.luckypool.io:3111";
    std::string wallet;
    std::string worker;
    std::string pass = "x";
    // Character(s) joining wallet and worker in the stratum login. LuckyPool expects
    // "wallet.worker"; some pools, such as Kryptex, expect "wallet/worker".
    std::string login_separator = ".";
    int device = 0;
    int pipeline = 2;
    bool pipeline_set = false;
    int max_runtime_sec = 0;
    int ntrims = -1;
    int gena_blocks = -1;
    int gena_tpb = -1;
    int genb_tpb = -1;
    int trim_tpb = -1;
    int tail_tpb = -1;
    int recover_blocks = -1;
    int recover_tpb = -1;
};

static std::string default_worker() {
    char name[128] = {0};
#if defined(_WIN32)
    DWORD n = sizeof(name);
    if (GetComputerNameA(name, &n)) return name;
#else
    if (gethostname(name, sizeof(name) - 1) == 0) return name;
#endif
    return "worker";
}

static void usage() {
    printf("usage: tari_c29_pool_miner --wallet WALLET [options]\n"
           "options:\n"
           "  --pool host:port        default taric29-ca.luckypool.io:3111\n"
           "  --worker name           default hostname\n"
           "  --pass x                default x\n"
           "  --login-separator s     joins wallet and worker in the pool login, default \".\"\n"
           "                          (use \"/\" for pools expecting wallet/worker)\n"
           "  --device N              default 0\n"
           "  --pipeline N            solver contexts to overlap GPU trim and CPU cycle search, default auto\n"
           "  --max-runtime-sec N     stop after N seconds (test helper)\n"
           "  --version               print version and exit\n"
           "tuning:\n"
           "  --ntrims N              even trim-round count, build default\n"
           "  --gena-blocks N         SeedA blocks, default 32768 bounded by graph size\n"
           "  --gena-tpb N            SeedA threads/block, default 128\n"
           "  --genb-tpb N            SeedB threads/block, default 128\n"
           "  --trim-tpb N            trim rounds threads/block, default 320\n"
           "  --tail-tpb N            tail threads/block, default 1024\n"
           "  --recover-blocks N      recovery blocks, default 1024 bounded by graph size\n"
           "  --recover-tpb N         recovery threads/block, default 1024\n");
}

static bool parse_args(int argc, char **argv, Options &o) {
    for (int i = 1; i < argc; ++i) {
        auto need = [&](const char *name) -> char * {
            if (i + 1 >= argc) {
                fprintf(stderr, "%s needs a value\n", name);
                return nullptr;
            }
            return argv[++i];
        };
        if (!strcmp(argv[i], "--pool")) { char *v = need(argv[i]); if (!v) return false; o.pool = v; }
        else if (!strcmp(argv[i], "--wallet")) { char *v = need(argv[i]); if (!v) return false; o.wallet = v; }
        else if (!strcmp(argv[i], "--worker")) { char *v = need(argv[i]); if (!v) return false; o.worker = v; }
        else if (!strcmp(argv[i], "--pass")) { char *v = need(argv[i]); if (!v) return false; o.pass = v; }
        else if (!strcmp(argv[i], "--login-separator")) { char *v = need(argv[i]); if (!v) return false; o.login_separator = v; }
        else if (!strcmp(argv[i], "--device")) { char *v = need(argv[i]); if (!v) return false; o.device = atoi(v); }
        else if (!strcmp(argv[i], "--pipeline")) { char *v = need(argv[i]); if (!v) return false; o.pipeline = atoi(v); o.pipeline_set = true; }
        else if (!strcmp(argv[i], "--max-runtime-sec")) { char *v = need(argv[i]); if (!v) return false; o.max_runtime_sec = atoi(v); }
        else if (!strcmp(argv[i], "--ntrims")) { char *v = need(argv[i]); if (!v) return false; o.ntrims = atoi(v); }
        else if (!strcmp(argv[i], "--gena-blocks")) { char *v = need(argv[i]); if (!v) return false; o.gena_blocks = atoi(v); }
        else if (!strcmp(argv[i], "--gena-tpb")) { char *v = need(argv[i]); if (!v) return false; o.gena_tpb = atoi(v); }
        else if (!strcmp(argv[i], "--genb-tpb")) { char *v = need(argv[i]); if (!v) return false; o.genb_tpb = atoi(v); }
        else if (!strcmp(argv[i], "--trim-tpb")) { char *v = need(argv[i]); if (!v) return false; o.trim_tpb = atoi(v); }
        else if (!strcmp(argv[i], "--tail-tpb")) { char *v = need(argv[i]); if (!v) return false; o.tail_tpb = atoi(v); }
        else if (!strcmp(argv[i], "--recover-blocks")) { char *v = need(argv[i]); if (!v) return false; o.recover_blocks = atoi(v); }
        else if (!strcmp(argv[i], "--recover-tpb")) { char *v = need(argv[i]); if (!v) return false; o.recover_tpb = atoi(v); }
        else if (!strcmp(argv[i], "--version")) { printf("TARI.Miner C29 %s\n", TARI_MINER_VERSION); exit(0); }
        else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) { usage(); exit(0); }
        else {
            fprintf(stderr, "unknown option: %s\n", argv[i]);
            return false;
        }
    }
    if (o.worker.empty()) o.worker = default_worker();
    if (o.wallet.empty()) {
        fprintf(stderr, "--wallet is required\n");
        return false;
    }
    if (o.pipeline < 1) o.pipeline = 1;
    if (o.pipeline > TARI_C29_MAX_PIPELINE) o.pipeline = TARI_C29_MAX_PIPELINE;
    return true;
}

int main(int argc, char **argv) {
    Options opt;
    if (!parse_args(argc, argv, opt)) {
        usage();
        return 2;
    }
    if (socket_init() != 0) {
        fprintf(stderr, "socket init failed\n");
        return 1;
    }

    cudaSetDevice(opt.device);
    cudaDeviceProp prop;
    if (cudaGetDeviceProperties(&prop, opt.device) != cudaSuccess) {
        fprintf(stderr, "no CUDA device %d\n", opt.device);
        socket_cleanup();
        return 1;
    }
    // Five contexts can page under WDDM on 32 GB cards and run slower than four.
    if (!opt.pipeline_set && prop.totalGlobalMem >= (28ull << 30))
        opt.pipeline = TARI_C29_MAX_PIPELINE < 4 ? TARI_C29_MAX_PIPELINE : 4;
    printf("TARI.Miner C29 %s on %s (%.0f GB, sm_%d%d)\n",
           TARI_MINER_VERSION, prop.name, prop.totalGlobalMem / 1e9, prop.major, prop.minor);
    printf("pool=%s worker=%s\n", opt.pool.c_str(), opt.worker.c_str());

    SolverParams params;
    fill_default_params(&params);
    params.device = opt.device;
    params.mutate_nonce = false;
    if (opt.ntrims > 0) params.ntrims = opt.ntrims & -2;
    if (opt.gena_blocks > 0) params.genablocks = opt.gena_blocks;
    if (opt.gena_tpb > 0) params.genatpb = opt.gena_tpb;
    if (opt.genb_tpb > 0) params.genbtpb = opt.genb_tpb;
    if (opt.trim_tpb > 0) params.trimtpb = opt.trim_tpb;
    if (opt.tail_tpb > 0) params.tailtpb = opt.tail_tpb;
    if (opt.recover_blocks > 0) params.recoverblocks = opt.recover_blocks;
    if (opt.recover_tpb > 0) params.recovertpb = opt.recover_tpb;
    std::vector<SolverCtx*> contexts;
    SolverCtx *ctx = create_solver_ctx(&params);
    if (!ctx || !ctx->trimmer.initsuccess) {
        fprintf(stderr, "failed to init solver (need ~6GB VRAM). reason: %s\n", LAST_ERROR_REASON);
        socket_cleanup();
        return 1;
    }
    contexts.push_back(ctx);
    for (int i = 1; i < opt.pipeline; ++i) {
        if (!have_device_memory_for_extra_solver_ctx(contexts[0])) {
            fprintf(stderr, "warning: not enough free VRAM for pipeline solver %d; using pipeline=%zu\n",
                    i, contexts.size());
            break;
        }
        SolverCtx *extra = create_solver_ctx(&params);
        if (!extra || !extra->trimmer.initsuccess) {
            fprintf(stderr, "warning: pipeline solver %d init failed; using pipeline=%zu. reason: %s\n",
                    i, contexts.size(), LAST_ERROR_REASON);
            cudaGetLastError();
            if (extra) destroy_solver_ctx(extra);
            break;
        }
        contexts.push_back(extra);
    }
    opt.pipeline = (int)contexts.size();
    printf("solver pipeline=%d context%s\n", opt.pipeline, opt.pipeline == 1 ? "" : "s");

    uint64_t graphs = 0, cycles = 0, submitted = 0, verify_failures = 0;
    double start = now_sec();
    double last_report = start;

    while (true) {
        double elapsed = now_sec() - start;
        if (opt.max_runtime_sec > 0 && elapsed >= opt.max_runtime_sec) break;

        std::string login = opt.wallet + opt.login_separator + opt.worker;
        printf("connecting to %s as %s\n", opt.pool.c_str(), login.c_str());

        PoolClient pool;
        if (!pool.connect_login(opt.pool, login, opt.pass)) {
            fprintf(stderr, "pool connection/login send failed; retrying in 5s\n");
            std::this_thread::sleep_for(std::chrono::seconds(5));
            continue;
        }

        Job job;
        if (!pool.wait_for_job(job, 20000)) {
            fprintf(stderr, "no job received; reconnecting\n");
            continue;
        }

        uint64_t last_seq = 0;
        uint64_t base = 0, mask = ~0ULL, counter = 0;

        auto derive_keys = [&](uint64_t nonce, const Job &j) -> siphash_keys {
            tari_siphash_keys k;
            tari_c29_derive_keys(nonce, j.mining_hash, &k);
            siphash_keys sk;
            sk.k0 = k.k0;
            sk.k1 = k.k1;
            sk.k2 = k.k2;
            sk.k3 = k.k3;
            return sk;
        };

        auto inject_keys = [&](SolverCtx *c, uint64_t nonce, const Job &j) {
            c->trimmer.sipkeys = derive_keys(nonce, j);
            c->sols.clear();
        };

        auto consume_solutions = [&](SolverCtx *c, const Job &sol_job, uint64_t nonce) {
            int nsols = (int)(c->sols.size() / TARI_C29_PROOFSIZE);
            for (int s = 0; s < nsols; ++s) {
                uint32_t edges[TARI_C29_PROOFSIZE];
                for (int i = 0; i < TARI_C29_PROOFSIZE; ++i)
                    edges[i] = c->sols[s * TARI_C29_PROOFSIZE + i];
                int rc = tari_c29_verify(nonce, sol_job.mining_hash, edges);
                if (rc != TARI_C29_OK) {
                    verify_failures++;
                    continue;
                }
                cycles++;
                uint64_t diff = tari_c29_check(nonce, sol_job.mining_hash, edges);
                if (diff >= sol_job.target_diff) {
                    printf("share diff=%llu target=%llu nonce=%s\n",
                           (unsigned long long)diff, (unsigned long long)sol_job.target_diff,
                           nonce_hex_be(nonce).c_str());
                    if (pool.submit_share(sol_job, nonce, edges)) submitted++;
                }
            }
        };

        auto report_speed = [&]() {
            double t = now_sec();
            if (t - last_report >= 15.0) {
                double gsec = graphs / (t - start);
                printf("speed %.2f g/s | graphs=%llu cycles=%llu submitted=%llu accepted=%llu rejected=%llu\n",
                       gsec, (unsigned long long)graphs, (unsigned long long)cycles,
                       (unsigned long long)submitted, (unsigned long long)pool.accepted(),
                       (unsigned long long)pool.rejected());
                last_report = t;
            }
        };

        if (opt.pipeline <= 1) while (pool.alive()) {
            elapsed = now_sec() - start;
            if (opt.max_runtime_sec > 0 && elapsed >= opt.max_runtime_sec) break;

            job = pool.current_job();
            if (job.seq == 0) {
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
                continue;
            }
            if (job.seq != last_seq) {
                last_seq = job.seq;
                base = nonce_prefix_base(job.xn_hex, &mask);
                counter = ((uint64_t)(now_sec() * 1000000.0)) & mask;
            }

            uint64_t nonce = base | (counter++ & mask);
            inject_keys(ctx, nonce, job);

            int nsols = ctx->solve();
            graphs++;
            (void)nsols;
            consume_solutions(ctx, job, nonce);
            report_speed();
        } else {
#if SOLVER_PRELAUNCH_NEXT
            struct HostEdgeBuffer {
                uint2 *ptr = nullptr;
                bool pinned = false;
            };
            std::vector<HostEdgeBuffer> edge_buffers((size_t)opt.pipeline * 2);
            for (HostEdgeBuffer &b : edge_buffers) {
                if (cudaMallocHost((void **)&b.ptr, sizeof(uint2) * (size_t)MAXEDGES) == cudaSuccess)
                    b.pinned = true;
                else
                    b.ptr = new uint2[MAXEDGES];
            }

            struct PendingTrim {
                std::future<u32> future;
                Job job;
                uint64_t nonce = 0;
                siphash_keys keys;
                uint2 *edges = nullptr;
                bool active = false;
            };
            std::vector<PendingTrim> pending((size_t)opt.pipeline);
            std::vector<int> next_buffer((size_t)opt.pipeline, 0);
            uint64_t done = 0;

            auto launch_trim = [&](int slot) -> bool {
                double launch_elapsed = now_sec() - start;
                if (opt.max_runtime_sec > 0 && launch_elapsed >= opt.max_runtime_sec) return false;
                if (!pool.alive()) return false;
                Job launch_job = pool.current_job();
                if (launch_job.seq == 0) return false;
                if (launch_job.seq != last_seq) {
                    last_seq = launch_job.seq;
                    base = nonce_prefix_base(launch_job.xn_hex, &mask);
                    counter = ((uint64_t)(now_sec() * 1000000.0)) & mask;
                }
                uint64_t nonce = base | (counter++ & mask);
                SolverCtx *slot_ctx = contexts[(size_t)slot];
                int buf = next_buffer[(size_t)slot];
                next_buffer[(size_t)slot] = buf ^ 1;
                uint2 *out = edge_buffers[(size_t)slot * 2 + (size_t)buf].ptr;
                siphash_keys keys = derive_keys(nonce, launch_job);
                slot_ctx->trimmer.sipkeys = keys;
                slot_ctx->sols.clear();
                pending[(size_t)slot].job = launch_job;
                pending[(size_t)slot].nonce = nonce;
                pending[(size_t)slot].keys = keys;
                pending[(size_t)slot].edges = out;
                pending[(size_t)slot].active = true;
                pending[(size_t)slot].future = std::async(std::launch::async, [slot_ctx, out, device = opt.device]() -> u32 {
                    cudaSetDevice(device);
                    return slot_ctx->trim_copy_to(out);
                });
                return true;
            };

            auto drain_pending = [&]() {
                for (int slot = 0; slot < opt.pipeline; ++slot) {
                    if (pending[(size_t)slot].active) {
                        pending[(size_t)slot].future.get();
                        pending[(size_t)slot].active = false;
                    }
                }
            };

            for (int slot = 0; slot < opt.pipeline; ++slot) {
                if (!launch_trim(slot)) break;
            }

            while (pool.alive()) {
                elapsed = now_sec() - start;
                if (opt.max_runtime_sec > 0 && elapsed >= opt.max_runtime_sec) break;

                int slot = (int)(done % (uint64_t)opt.pipeline);
                if (!pending[(size_t)slot].active) {
                    if (!launch_trim(slot)) {
                        std::this_thread::sleep_for(std::chrono::milliseconds(50));
                        continue;
                    }
                }

                SolverCtx *slot_ctx = contexts[(size_t)slot];
                u32 nedges = pending[(size_t)slot].future.get();
                Job sol_job = pending[(size_t)slot].job;
                uint64_t nonce = pending[(size_t)slot].nonce;
                siphash_keys keys = pending[(size_t)slot].keys;
                uint2 *edge_buf = pending[(size_t)slot].edges;
                pending[(size_t)slot].active = false;

                launch_trim(slot);

                slot_ctx->sols.clear();
                if (nedges)
                    slot_ctx->findcycles_with_keys(edge_buf, nedges, keys, slot_ctx->sols);
                graphs++;
                consume_solutions(slot_ctx, sol_job, nonce);
                done++;
                report_speed();
            }
            drain_pending();
            for (HostEdgeBuffer &b : edge_buffers) {
                if (b.pinned)
                    cudaFreeHost(b.ptr);
                else
                    delete[] b.ptr;
            }
#else
            struct PendingTrim {
                std::future<u32> future;
                Job job;
                uint64_t nonce = 0;
                bool active = false;
            };
            std::vector<PendingTrim> pending((size_t)opt.pipeline);
            uint64_t done = 0;

            auto launch_trim = [&](int slot) -> bool {
                double launch_elapsed = now_sec() - start;
                if (opt.max_runtime_sec > 0 && launch_elapsed >= opt.max_runtime_sec) return false;
                if (!pool.alive()) return false;
                Job launch_job = pool.current_job();
                if (launch_job.seq == 0) return false;
                if (launch_job.seq != last_seq) {
                    last_seq = launch_job.seq;
                    base = nonce_prefix_base(launch_job.xn_hex, &mask);
                    counter = ((uint64_t)(now_sec() * 1000000.0)) & mask;
                }
                uint64_t nonce = base | (counter++ & mask);
                SolverCtx *slot_ctx = contexts[(size_t)slot];
                inject_keys(slot_ctx, nonce, launch_job);
                pending[(size_t)slot].job = launch_job;
                pending[(size_t)slot].nonce = nonce;
                pending[(size_t)slot].active = true;
                pending[(size_t)slot].future = std::async(std::launch::async, [slot_ctx, device = opt.device]() -> u32 {
                    cudaSetDevice(device);
                    return slot_ctx->trim_copy();
                });
                return true;
            };

            auto drain_pending = [&]() {
                for (int slot = 0; slot < opt.pipeline; ++slot) {
                    if (pending[(size_t)slot].active) {
                        pending[(size_t)slot].future.get();
                        pending[(size_t)slot].active = false;
                    }
                }
            };

            for (int slot = 0; slot < opt.pipeline; ++slot) {
                if (!launch_trim(slot)) break;
            }

            while (pool.alive()) {
                elapsed = now_sec() - start;
                if (opt.max_runtime_sec > 0 && elapsed >= opt.max_runtime_sec) break;

                int slot = (int)(done % (uint64_t)opt.pipeline);
                if (!pending[(size_t)slot].active) {
                    if (!launch_trim(slot)) {
                        std::this_thread::sleep_for(std::chrono::milliseconds(50));
                        continue;
                    }
                }

                SolverCtx *slot_ctx = contexts[(size_t)slot];
                u32 nedges = pending[(size_t)slot].future.get();
                pending[(size_t)slot].active = false;
                if (nedges)
                    slot_ctx->findcycles_copied(nedges);
                graphs++;
                consume_solutions(slot_ctx, pending[(size_t)slot].job, pending[(size_t)slot].nonce);
                done++;
                launch_trim(slot);
                report_speed();
            }
            drain_pending();
#endif
        }
    }

    double elapsed = now_sec() - start;
    printf("\n--- summary ---\n");
    printf("graphs=%llu elapsed=%.2fs speed=%.3f g/s cycles=%llu submitted=%llu verify_failures=%llu\n",
           (unsigned long long)graphs, elapsed, graphs / elapsed,
           (unsigned long long)cycles, (unsigned long long)submitted,
           (unsigned long long)verify_failures);
    for (SolverCtx *c : contexts)
        destroy_solver_ctx(c);
    socket_cleanup();
    return verify_failures ? 3 : 0;
}
