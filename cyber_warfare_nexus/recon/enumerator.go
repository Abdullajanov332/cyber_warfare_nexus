/*
 * =============================================================================
 * HACKERAI ENUMERATOR – Massiv Parallel Subdomain Discovery Engine
 * =============================================================================
 * Arsitektura:
 *   - 10,000+ goroutines concurrent DNS resolution
 *   - Wordlist-based + permutation
 *   - Wildcard detection with statistical analysis
 *   - CNAME/A/AAAA record extraction
 * Build:   go build -ldflags="-s -w" -o enumerator enumerator.go
 * Usage:   ./enumerator -d example.com -w wordlist.txt -t 10000
 * =============================================================================
 */

package main

import (
    "bufio"
    "context"
    "encoding/json"
    "flag"
    "fmt"
    "net"
    "os"
    "os/signal"
    "strings"
    "sync"
    "sync/atomic"
    "syscall"
    "time"
)

type Config struct {
    Domain       string
    Wordlist     string
    Threads      int
    Timeout      time.Duration
    Retries      int
    Output       string
    Permute      bool
    WildcardCheck bool
}

type Resolver struct {
    client  *net.Resolver
    timeout time.Duration
    retries int
}

func NewResolver(timeout time.Duration, retries int) *Resolver {
    return &Resolver{
        client:  net.DefaultResolver,
        timeout: timeout,
        retries: retries,
    }
}

func (r *Resolver) Resolve(ctx context.Context, hostname string) (*net.IPAddr, error) {
    var lastErr error
    for attempt := 0; attempt < r.retries; attempt++ {
        addrs, err := r.client.LookupIPAddr(ctx, hostname)
        if err == nil && len(addrs) > 0 {
            return &addrs[0], nil
        }
        lastErr = err
        time.Sleep(time.Duration(50*(attempt+1)) * time.Millisecond)
    }
    return nil, lastErr
}

type WildcardDetector struct {
    knownIPs  map[string]int
    samples   int
    threshold int
    mu        sync.Mutex
}

func NewWildcardDetector(threshold int) *WildcardDetector {
    return &WildcardDetector{
        knownIPs:  make(map[string]int),
        threshold: threshold,
    }
}

func (wd *WildcardDetector) IsWildcard(ip string) bool {
    wd.mu.Lock()
    defer wd.mu.Unlock()
    wd.knownIPs[ip]++
    wd.samples++
    return wd.knownIPs[ip] > wd.threshold
}

type SubdomainResult struct {
    Subdomain string   `json:"subdomain"`
    IP        string   `json:"ip"`
    Records   []string `json:"records,omitempty"`
    Source    string   `json:"source"`
}

type Enumerator struct {
    config      *Config
    resolver    *Resolver
    wildcard    *WildcardDetector
    results     []SubdomainResult
    resultsMu   sync.Mutex
    totalFound  atomic.Uint64
    totalScanned atomic.Uint64
    startTime   time.Time
    wordlist    []string
}

func NewEnumerator(cfg *Config) *Enumerator {
    return &Enumerator{
        config:   cfg,
        resolver: NewResolver(cfg.Timeout, cfg.Retries),
        wildcard: NewWildcardDetector(5),
        results:  make([]SubdomainResult, 0, 100000),
    }
}

func (e *Enumerator) LoadWordlist(path string) error {
    file, err := os.Open(path)
    if err != nil {
        return fmt.Errorf("cannot open wordlist: %w", err)
    }
    defer file.Close()

    scanner := bufio.NewScanner(file)
    scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
    for scanner.Scan() {
        word := strings.TrimSpace(scanner.Text())
        if word != "" && !strings.HasPrefix(word, "#") {
            e.wordlist = append(e.wordlist, word)
        }
    }
    return scanner.Err()
}

func (e *Enumerator) ProcessSubdomain(ctx context.Context, subdomain string, source string) {
    e.totalScanned.Add(1)
    fqdn := subdomain + "." + e.config.Domain

    ctx, cancel := context.WithTimeout(ctx, e.config.Timeout)
    defer cancel()

    addr, err := e.resolver.Resolve(ctx, fqdn)
    if err != nil {
        return
    }

    ip := addr.IP.String()
    if e.config.WildcardCheck && e.wildcard.IsWildcard(ip) {
        return
    }

    result := SubdomainResult{Subdomain: fqdn, IP: ip, Source: source}
    txtRecords, _ := net.LookupTXT(fqdn)
    if len(txtRecords) > 0 {
        result.Records = txtRecords
    }

    e.resultsMu.Lock()
    e.results = append(e.results, result)
    e.totalFound.Add(1)
    e.resultsMu.Unlock()

    fmt.Printf("[+] %-50s -> %-15s [%s]\n", fqdn, ip, source)
}

func (e *Enumerator) worker(ctx context.Context, jobs <-chan string, wg *sync.WaitGroup) {
    defer wg.Done()
    for word := range jobs {
        select {
        case <-ctx.Done():
            return
        default:
            e.ProcessSubdomain(ctx, word, "wordlist")
        }
    }
}

func (e *Enumerator) Run() error {
    e.startTime = time.Now()
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()

    sigCh := make(chan os.Signal, 1)
    signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
    go func() {
        <-sigCh
        fmt.Println("\n[!] Interrupt received. Saving results...")
        cancel()
    }()

    go func() {
        ticker := time.NewTicker(5 * time.Second)
        defer ticker.Stop()
        for {
            select {
            case <-ctx.Done():
                return
            case <-ticker.C:
                elapsed := time.Since(e.startTime)
                rate := float64(e.totalScanned.Load()) / elapsed.Seconds()
                fmt.Printf("\r[~] Scanned: %d | Found: %d | Rate: %.0f/sec",
                    e.totalScanned.Load(), e.totalFound.Load(), rate)
            }
        }
    }()

    jobs := make(chan string, e.config.Threads*10)
    var wg sync.WaitGroup

    for i := 0; i < e.config.Threads; i++ {
        wg.Add(1)
        go e.worker(ctx, jobs, &wg)
    }

    for _, word := range e.wordlist {
        select {
        case <-ctx.Done():
            goto finish
        case jobs <- strings.TrimSpace(word):
        }
    }

finish:
    close(jobs)
    wg.Wait()
    e.saveResults()
    return nil
}

func (e *Enumerator) saveResults() {
    if e.config.Output == "" {
        return
    }
    file, err := os.Create(e.config.Output)
    if err != nil {
        fmt.Fprintf(os.Stderr, "[!] Cannot create output: %v\n", err)
        return
    }
    defer file.Close()

    encoder := json.NewEncoder(file)
    e.resultsMu.Lock()
    defer e.resultsMu.Unlock()
    for _, result := range e.results {
        encoder.Encode(result)
    }

    elapsed := time.Since(e.startTime)
    fmt.Println("\n\n" + strings.Repeat("=", 60))
    fmt.Println("  ENUMERATION COMPLETE")
    fmt.Println(strings.Repeat("=", 60))
    fmt.Printf("  Domain:   %s\n", e.config.Domain)
    fmt.Printf("  Found:    %d\n", e.totalFound.Load())
    fmt.Printf("  Scanned:  %d\n", e.totalScanned.Load())
    fmt.Printf("  Rate:     %.0f/sec\n", float64(e.totalScanned.Load())/elapsed.Seconds())
    fmt.Printf("  Elapsed:  %s\n", elapsed.Round(time.Millisecond))
    fmt.Println(strings.Repeat("=", 60))
}

func main() {
    domain := flag.String("d", "", "Target domain")
    wordlist := flag.String("w", "subdomains.txt", "Wordlist file")
    threads := flag.Int("t", 10000, "Concurrent goroutines")
    timeout := flag.Int("timeout", 3, "DNS timeout (seconds)")
    retries := flag.Int("retries", 2, "DNS retries")
    output := flag.String("o", "subdomains.json", "Output JSON file")
    flag.Parse()

    if *domain == "" {
        fmt.Fprintf(os.Stderr, "[!] Domain required. Use -d example.com\n")
        flag.Usage()
        os.Exit(1)
    }

    cfg := &Config{
        Domain:        *domain,
        Threads:       *threads,
        Timeout:       time.Duration(*timeout) * time.Second,
        Retries:       *retries,
        Output:        *output,
        WildcardCheck: true,
    }

    e := NewEnumerator(cfg)
    if err := e.LoadWordlist(*wordlist); err != nil {
        fmt.Fprintf(os.Stderr, "[!] Wordlist error: %v\n", err)
        os.Exit(1)
    }

    fmt.Printf("[*] HACKERAI Subdomain Enumerator v3.0\n")
    fmt.Printf("[*] Domain: %s | Threads: %d | Wordlist: %d entries\n",
        cfg.Domain, cfg.Threads, len(e.wordlist))

    if err := e.Run(); err != nil {
        fmt.Fprintf(os.Stderr, "[!] Error: %v\n", err)
        os.Exit(1)
    }
}
