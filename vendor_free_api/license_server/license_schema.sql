-- IPTunnel License Server — Schema
-- Deployed at license.internetshub.com

CREATE TABLE IF NOT EXISTS servers (
    server_id   TEXT PRIMARY KEY,                       -- UUID issued at registration
    ip          TEXT NOT NULL,                           -- VPS public IP
    hostname    TEXT NOT NULL DEFAULT '',                -- optional friendly name
    token       TEXT NOT NULL,                           -- master or user token used to register
    registered_at TEXT NOT NULL DEFAULT (datetime('now')),
    last_checkin  TEXT,                                  -- NULL until first check-in
    revoked     INTEGER NOT NULL DEFAULT 0,             -- 1 = blocked
    note        TEXT NOT NULL DEFAULT ''                 -- admin memo
);

CREATE INDEX IF NOT EXISTS idx_servers_ip    ON servers(ip);
CREATE INDEX IF NOT EXISTS idx_servers_token ON servers(token);
