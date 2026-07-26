-- =============================================================================
-- HACKERAI INTELLIGENCE DATABASE SCHEMA 
-- Barcha ma'lumotlar AES-256-GCM bilan shifrlanadi
-- =============================================================================

PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
PRAGMA key='AES256_ENCRYPTION_KEY_32BYTES!!';

-- TARGETLAR VA HOSTLAR
CREATE TABLE IF NOT EXISTS targets (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ip_address TEXT NOT NULL,
    hostname TEXT,
    domain TEXT,
    os_fingerprint TEXT,
    first_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
    last_seen DATETIME,
    risk_score REAL DEFAULT 0.0,
    is_alive BOOLEAN DEFAULT 0,
    tags TEXT
);

-- PORTLAR VA XIZMATLAR
CREATE TABLE IF NOT EXISTS ports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    target_id INTEGER NOT NULL,
    port INTEGER NOT NULL CHECK(port BETWEEN 1 AND 65535),
    protocol TEXT DEFAULT 'tcp',
    service TEXT,
    banner TEXT,
    service_version TEXT,
    is_open BOOLEAN DEFAULT 0,
    FOREIGN KEY(target_id) REFERENCES targets(id) ON DELETE CASCADE
);

-- ZAIFLIKLAR (CVE ma'lumotlari bilan)
CREATE TABLE IF NOT EXISTS vulnerabilities (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    target_id INTEGER NOT NULL,
    port_id INTEGER,
    cve_id TEXT,
    cvss_score REAL,
    description TEXT,
    exploit_available BOOLEAN DEFAULT 0,
    exploit_path TEXT,
    remediation TEXT,
    discovered_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    is_exploited BOOLEAN DEFAULT 0,
    FOREIGN KEY(target_id) REFERENCES targets(id) ON DELETE CASCADE,
    FOREIGN KEY(port_id) REFERENCES ports(id) ON DELETE SET NULL
);

-- SUBDOMENLAR
CREATE TABLE IF NOT EXISTS subdomains (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    domain TEXT NOT NULL,
    subdomain TEXT NOT NULL,
    ip_address TEXT,
    resolved BOOLEAN DEFAULT 0,
    source TEXT DEFAULT 'bruteforce',
    discovered_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- CREDENTIALS (shifrlangan)
CREATE TABLE IF NOT EXISTS credentials (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    target_id INTEGER NOT NULL,
    username TEXT NOT NULL,
    password_hash TEXT,
    password_plain TEXT,
    hash_type TEXT,
    service TEXT,
    source TEXT,
    cracked BOOLEAN DEFAULT 0,
    FOREIGN KEY(target_id) REFERENCES targets(id) ON DELETE CASCADE
);

-- SESSIONS VA ACCESS
CREATE TABLE IF NOT EXISTS sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    target_id INTEGER NOT NULL,
    session_token TEXT,
    shell_type TEXT,
    host_os TEXT,
    is_active BOOLEAN DEFAULT 1,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    last_seen DATETIME,
    FOREIGN KEY(target_id) REFERENCES targets(id) ON DELETE CASCADE
);

-- OPERATION LOGLARI
CREATE TABLE IF NOT EXISTS operations_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    module TEXT NOT NULL,
    action TEXT NOT NULL,
    target TEXT,
    status TEXT CHECK(status IN ('success','failed','running','queued')),
    output TEXT,
    error_message TEXT,
    duration_ms INTEGER
);

-- INDEXLAR
CREATE INDEX idx_targets_ip ON targets(ip_address);
CREATE INDEX idx_ports_target ON ports(target_id);
CREATE INDEX idx_vulns_cve ON vulnerabilities(cve_id);
CREATE INDEX idx_subdomains_domain ON subdomains(domain);
CREATE INDEX idx_creds_target ON credentials(target_id);
CREATE INDEX idx_logs_timestamp ON operations_log(timestamp);
