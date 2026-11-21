# Architecture

This document describes the runtime structure of `perl5-mt-shop`, how sessions
and shared state are coordinated inside `perl5-mt`, and how the benchmark
numbers in `README.md` were measured.

## Process and Concurrency Model

`bin/shop-server` runs as a single OS process containing multiple `perl5-mt`
worker threads:

1. **Startup and Image Freeze**: All `MT::*`, `Shop::*`, and (when present)
   `mojolicious-mt` modules are loaded in the main thread, configuration and
   the Ed25519 host key are read, the database schema is verified, and hot
   inventory is loaded into shared state. `Mojo::MT::prepare_for_freeze()` and
   `MT::Image::freeze()` are called once before any worker thread is spawned so
   the compiled optrees and read-only structures are shared across threads.
2. **Acceptor Loop (Main Thread)**: A non-blocking TCP listener (`Listen =>
   1024`) accepts connections on `ssh.host:ssh.port` (default `0.0.0.0:2222`),
   checks the pre-fiber DoS blackhole and in-process per-IP rate limiter,
   enables `SO_KEEPALIVE` on accepted sockets, duplicates the client file
   descriptor via `POSIX::dup`, and sends the fd over a bounded `MT::Channel`
   (capacity 256). Every 250 ms it calls `MT::Supervisor::tick()`.
3. **Session Workers and Stackful Fibers**: `workers.session_workers` (default
   4) `MT::Worker` OS threads pull client fds from the connection channel.
   Inside each worker, a dispatcher fiber uses a per-worker `IO::Poll` loop to
   spawn one `MT::Fiber` per SSH connection and wake parked fibers
   (`MT::Fiber::park()`) when their socket or EventBus inbox is ready. Fibers
   run cooperatively on a configurable stack (`MT_FIBER_STACK`, tested at 32
   KiB / `32768` bytes) and disconnect inactive sessions after
   `ssh.idle_timeout_sec` (default 1800 s).
4. **Background Workers**:
   - `db_pool` (`MT::Pool`, default 2 workers): database worker pool.
   - `checkpoint_worker`: writes `MT::Checkpoint` inventory snapshots on a
     fixed interval (`workers.checkpoint_interval_sec`, default 30 s).
   - `reaper_worker`: periodic KeyDB health ping (with automatic reconnect on
     connection errors), scheduled subscription renewals, `prune_rate_limits`
     every 60 s, and expired blackhole ban pruning.
   - `ops_worker`: non-blocking HTTP/1.1 server (`Shop::Webhook::Server`) that
     instantiates `Shop::Web::App` on `Mojo::Server::Daemon` +
     `Mojo::Reactor::MT` + `Mojo::MT::Accel` inside the frozen worker thread
     (with a raw-socket `select()` fallback if `mojolicious-mt` is absent),
     serving `GET /healthz`, `GET /metrics`, `GET /api/catalog`,
     `GET /api/memberships`, `GET /api/cluster`, `POST /webhooks/stripe`, and
     `POST /webhooks/shippo`. Webhook idempotency uses KeyDB when available
     with a bounded in-process `MT::SharedHash` fallback (capped at 10,000
     entries). A 50 ms recurring `Mojo::IOLoop` timer calls
     `MT::Supervisor::beat()` and polls the shared shutdown `MT::Cell` for
     clean `SIGINT`/`SIGTERM` exit.
5. **Fault Observation**: `MT::Fault::on` logs worker faults and increments
   `supervisor_faults_total` in `Shop::Metrics`.

## SSHv2 Transport and Tier-1 XS Crypto

The SSH server is implemented in `lib/Shop/SSH/` (`Transport.pm`, `Wire.pm`,
`Auth.pm`, `Session.pm`, `Crypto.pm`) backed by a C/XS extension in
`xs/Shop-SSH-Crypto/`.

- **Thread-Safe XS**: `xs/Shop-SSH-Crypto/Makefile.PL` compiles with
  `-DPERL_XS_THREADSAFE=1` and links directly against `libsodium`, OpenSSL
  `libcrypto`, and `zlib`. Every `MT::Worker` thread calls crypto and
  compression routines directly in-process.
- **Key Exchange**: Supports `mlkem768x25519-sha256` (hybrid ML-KEM-768 via
  OpenSSL EVP + X25519 via libsodium, combined with SHA-256) and classical
  `curve25519-sha256`.
- **Strict KEX and Rekeying**: Implements `kex-strict-s-v00@openssh.com`
  (sequence number reset on `NEWKEYS` and rejection of unexpected pre-`NEWKEYS`
  packets), mid-session rekeying (default threshold 512 MiB), `ext-info-s`,
  and `keepalive@openssh.com`.
- **Ciphers and Auth**: `chacha20-poly1305@openssh.com` (libsodium) and
  `aes256-gcm@openssh.com` (OpenSSL EVP). User public-key verification supports
  `ssh-ed25519`, `ecdsa-sha2-nistp256`, `rsa-sha2-256`, and `rsa-sha2-512`.
- **Wire Compression**: Delayed streaming `zlib@openssh.com` (`Z_SYNC_FLUSH`,
  configurable level, default 5) activates after `SSH_MSG_USERAUTH_SUCCESS`.
  `Zlib::inflate` enforces an output cap (`SSH_ZIP_BOMB`) to bound memory on
  malformed compressed packets.
- **Packet Cap**: Maximum packet size is capped at 256 KiB (`262144` bytes).

## Double-Buffered ANSI Diff Renderer

`lib/Shop/TUI/Screen.pm` manages terminal rendering per session:

- **Packed Buffers**: Previous and current frames are stored in four
  `MT::Array::packed('IV', ...)` contiguous 64-bit integer arrays (`curr_ch`,
  `curr_st`, `prev_ch`, `prev_st`) to avoid per-cell Perl scalar overhead.
- **64-Bit Packed Style IDs**: Foreground color (bits 0..24), background color
  (bits 25..49), and attribute flags (`bold`, `dim`, `rev`, `ul` in bits
  50..53) pack into one integer for single-instruction cell equality checks.
  Color output degrades cleanly to `truecolor`, `256`, or `16` based on `TERM`
  and `COLORTERM` captured from SSH `env` requests.
- **Grapheme Width**: Printable ASCII uses a fast path; non-ASCII text is
  segmented with Unicode UAX #29 extended grapheme clusters (`\X`) and clipped
  by display width.
- **Egress Minimization**:
  - Unchanged rows are skipped completely; idle frames emit 0 bytes.
  - Cursor movement chooses between sequential advance, relative hops, or
    direct `\e[row;colH` positioning.
  - Trailing blank runs use `\e[K` (erase to end of line).
  - SGR attributes emit minimal deltas rather than full resets where shorter.
  - Frames are wrapped in synchronized output markers (`\e[?2026h` /
    `\e[?2026l`).
- **Input and Mouse**: `lib/Shop/TUI/Input.pm` parses UTF-8 keys, CSI/SS3
  escape sequences, and SGR mouse events (`\e[?1000h\e[?1006h`) for clicks and
  scroll wheel navigation.

## Hot-Tier State, EventBus, and Checkpoints

Hot reads and reservations stay in-process to avoid database round-trips on
every keypress:

- **Inventory (`Shop::State::Inventory`)**: Product metadata is stored in an
  `MT::SharedHash` (`products`). Each SKU's integer stock count lives in its
  own `MT::Cell`, indexed by a second `MT::SharedHash` (`cells`).
  `reserve($sku, $qty)` and `release($sku, $qty)` loop on `$cell->cas($cur,
  $nxt)`. Workers attach to both shared hashes by ID after `MT::Image::freeze`.
- **EventBus (`Shop::State::EventBus`)**: Active SSH sessions register their
  metadata and an inbox `MT::Channel` ID (default capacity 64) in a shared
  hash. On disconnect, `unregister_session()` drains the inbox channel and
  recycles its ID into a shared free-channel pool so session churn reuses
  existing channels without unbounded growth. `broadcast()` and `send_to_user()`
  deliver JSON payloads non-blockingly (dropping if a slow receiver's channel
  is at `cap - 1`) for stock updates, admin broadcasts, payment confirmations,
  and shipment tracking updates.
- **Checkpoints (`MT::Checkpoint`)**: `checkpoint_worker` periodically persists
  the inventory state to `checkpoint.path` (`var/inventory.mtck`), and a final
  snapshot is written on clean `SIGINT`/`SIGTERM` shutdown. On startup, the
  server loads from the database and overlays any existing checkpoint file.
- **Metrics (`Shop::Metrics`)**: Counters and gauges are pre-allocated
  `MT::Cell` instances in an `MT::SharedHash`, updated via CAS and rendered as
  Prometheus text on `GET /metrics`. Pre-auth IP rate limiting uses a second
  `MT::SharedHash`.

## Cooperative Clustering and Pre-Fiber DoS Blackhole

Multi-node operation is disabled by default (`cluster.enabled: false`) so
single-node deployments behave identically. When enabled with `--cluster`, three
modules coordinate routing and abuse mitigation:

- **Deterministic Wavefunction (`Shop::Cluster::Wavefunction`)**: Maintains a
  normalized complex state vector over the sorted list of active node IDs
  ($\|\psi\|_2 = 1$). Each logical step evolves via a split-step ring Laplacian
  propagator plus a load-repulsive phase kick without consulting wall-clock
  time, producing bit-identical `state_digest()` values across all nodes at the
  same step. Hilbert-space expansion and contraction (`resize()`) re-seed new
  nodes isometrically and renormalize. Connection routing maps `(peer_ip, seq)`
  through SHA-256 onto the load-weighted Born distribution so overloaded nodes
  shed traffic to lightly loaded peers.
- **Mesh Bus and L4 Splice (`Shop::Cluster::Mesh`)**: Periodically publishes
  local node state to KeyDB (`cluster:node:<id>` with 10 s TTL), scans active
  peers, advances the shared logical step via `INCR cluster:wave_step`, verifies
  same-step peer digest coherence, and stores the latest status JSON in an
  `MT::Cell` for lock-free reads by `GET /api/cluster` and the Admin dashboard.
  When `choose_node()` selects a remote peer, a session worker fiber splices the
  TCP stream at L4 (`relay_socket()` with `IO::Poll` and a single 8 KiB buffer)
  without decrypting SSH packets or allocating zlib/TUI state on the forwarding
  node.
- **DoS Blackhole (`Shop::Cluster::Blackhole`)**: Backed by `MT::SharedHash`
  (`bans` and `strikes`) and `MT::Cell` counters (`blackholed_count`,
  `banned_count`). The main accept loop checks `is_banned($peer_ip)` before
  rate limiting or fiber dispatch; banned peers are closed immediately via
  `shunt_socket()` (`SO_LINGER {1, 0}`, 0 fibers spawned, 0 bytes transmitted).
  Rate-limit trips and session protocol violations (Terrapin strict-KEX
  violation, `SSH_ZIP_BOMB`, invalid client banner, auth floods) increment
  strike scores via `record_violation()`, auto-banning repeat or severe
  offenders and syncing `dos:ban:<ip>` keys across cluster peers through KeyDB.

## How Memory and Egress Were Measured

- **Egress and Throughput (`bin/bench-egress-and-perf`)**:
  - Pricing: 10,000 iterations of `Shop::Domain::Pricing::calculate` on a
    3-item cart with a 20% promo code (`PERLMT20`) and tax.
  - CAS: 8 `MT::Worker` OS threads each running 5,000 reserve + 5,000 release
    pairs (80,000 total CAS ops) against a single contended SKU (`BENCH-SKU`),
    followed by a drift check (`stock == 1000`).
  - Egress: 100 consecutive 80x24 catalog frames with changing selection,
    header frame counter, cart count, and stock tick. For each frame, the
    script records the byte lengths of: (1) naive full-frame ANSI, (2)
    row-level line-diff ANSI, (3) `Shop::TUI::Screen->render()` cell-diff ANSI,
    and (4) cell-diff ANSI fed through `Shop::SSH::Crypto::Zlib->new(5)`.
- **1,000-Fiber RSS**:
  - Measured on macOS arm64 with `MT_FIBER_STACK=32768` by querying `ps -o
    rss= -p $$` before scheduling and again once 1,000 fibers had yielded at a
    shared barrier.
  - Bare fibers (no screen buffers): 20.0 MiB delta (20.5 KiB/fiber).
  - Fibers each allocating an 80x24 `Shop::TUI::Screen`: 130.9 MiB delta
    (134.0 KiB/fiber; each screen holds four 1,920-element 64-bit packed IV
    arrays, about 60 KiB of raw cell storage plus fiber stack and Perl frame
    overhead).
