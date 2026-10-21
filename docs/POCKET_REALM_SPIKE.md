# Pocket Realm Architecture & 4-Week Technical Spike Specification

## Overview

Pocket Realm is Open Vanilla's experimental showpiece: booting a lightweight Vanilla game server
inside a browser tab with WebWorker compute, WebRTC DataChannel multiplayer peers, and Origin Private
File System (OPFS) SQLite storage.

Its realistic primary role is **"Test in browser"** for Vanilla Forge packs and an instant zero-install
preview of a `realm.json` recipe, with friends-only co-op for 5–20 players.

---

## 1. Technical Feasibility & Foundations

1. **Precedents**:
   - **Haxball**: Headless host running browser-hosted rooms via WebRTC DataChannels for over a decade.
   - **2004Scape**: Complete Java/C-derived game server compiled to WebAssembly running in a WebWorker with WebRTC peer networking.
2. **Tab Keepalive & Background Throttling**:
   - Chrome explicitly exempts pages holding an open `RTCDataChannel` from intensive background timer throttling.
   - Active WebRTC connections and held `navigator.locks.request` Web Locks exempt the page from Chrome Energy Saver tab freezing.
3. **Storage Engine**:
   - Official SQLite-wasm on OPFS (Origin Private File System) maintains 100+ MB/s sequential throughput and sub-millisecond query latency on databases exceeding 1 GB.
   - `mangos-classic` maintains a native SQLite database backend in `src/shared/Database`.

---

## 2. 4-Week Spike Milestone Plan

### Week 1: Emscripten CMaNGOS-SQLite Compilation
- Target: Compile `mangos-classic` core with Emscripten (`emcc` / `em++`).
- Build Flags:
  - `-s USE_PTHREADS=1`
  - `-s WASM_MEM_MAX=2GB`
  - `-s ASYNCIFY=0` (native thread pool via SharedArrayBuffer)
  - `-DSQLITE=ON`
  - `-DENABLE_CLI=OFF`
  - `-DENABLE_RA=OFF`
- Headers: Serve with `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` (COOP/COEP).
- Deliverable: Headless `mangosd.wasm` initializing core subsystems and connecting to in-memory SQLite schema.

### Week 2: Virtual Session Transport Layer
- Problem: Browsers cannot open raw TCP listening sockets.
- Solution: Replace `boost::asio` socket acceptor with an abstraction: `VirtualSocketSession`.
  - For the host tab: Direct `MessagePort` / shared memory ringbuffer between host client and server worker.
  - For remote players: WebRTC `RTCDataChannel` (binary mode) bridged into the packet handler.
  - Bypass `realmd`: The share link (`openvanilla.app/r/{host_id}#pocket`) encapsulates the WebRTC signaling offer directly, eliminating the need for an external login server.

### Week 3: OPFS Database Persistence & Map Streaming
- Bind CMaNGOS database queries to SQLite-wasm via OPFS VFS.
- Implement virtual VFS chunk loader: stream DBC and collision tiles on-demand from indexed DB cache or unpacked `.ovpack`.
- Measure memory consumption under active map loading (must stay strictly under the 2 GB wasm32 Emscripten boundary).

### Week 4: Multi-Peer Integration & Fallback Assessment
- Connect 2 to 5 concurrent browser clients via WebRTC peer mesh.
- Measure tick time, packet serialization overhead, and latency jitter.
- Define Pass/Fail criteria:
  - **Pass**: Steady 50ms tick time with 5 connected clients moving and casting spells without memory crashes.
  - **Fail / Fallback**: If Emscripten pthreads or SQLite memory overflows the browser limit, transition to the **Rust Tourist Sim Co-op**: extend the existing Bevy/Rust `benilla` client into a peer-to-peer tourist mode with shared position synchronization and chat, reserving full Classic+ combat for H1/H2 compute.

---

## 3. Honest Real-World Constraints

- **Capacity**: 5–20 players maximum.
- **Trust Model**: Unranked, friends-only (Tier 3). The browser host holds raw memory and database write access; movement is client-trusted.
- **Tab Lifecycle**: Host must keep the tab open. Clear "Hosting Active — Keep this tab open" UI banner.
- **Mobile / iOS**: iOS Safari suspends WebAssembly workers aggressively on backgrounding; Pocket Realm is desktop-focused (Windows, macOS, Linux).
