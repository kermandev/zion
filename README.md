# Zion

Zion is a Linux load tester for Minecraft Java Edition servers. Written in Zig,
it uses `io_uring` and sharded event loops to simulate thousands of offline mode
clients with low per-client overhead.

## Requirements

- Linux 6.7 or newer with `io_uring` support.
- Zig 0.17. The current tree is tested with
  `0.17.0-dev.1415+64dfaa568`.
- A Minecraft Java server that accepts offline mode clients.
- A file descriptor limit at least as large as the requested client count.

Zion does not support macOS or Windows. It uses `std.Io` for readers, writers,
files, clocks, and sleeps, while driving `std.os.linux.IoUring` directly. Zig's
evented Linux networking backend does not yet provide all the listen, accept,
connect, send, write, and batched receive operations Zion requires.

## Build

```sh
zig build -Doptimize=ReleaseFast
```

The binary is written to `zig-out/bin/zion`. Full LTO is enabled for non-Debug
builds.

To create stripped, static release archives for every supported Minecraft
version:

```sh
scripts/release
```

The version catalog is defined in `src/protocol/versions/catalog.zig`. Archives
and `SHA256SUMS` are written to `dist/`.

The base x86-64 release is labeled `linux-x86_64-v3`;
`linux-x86_64-v4` targets newer processors. Baseline and v2 archives are not
published, but users of older x86-64 processors can compile Zion for their own
CPU. The CPU ISA level does not change the Linux kernel requirement.

Each platform has a `full` archive with every optional feature and a `minimal`
archive built with `-Dminimal=true`. Archive names always end with the variant.

Use the minimal preset for the smallest binary and lowest per-client overhead:

```sh
zig build -Doptimize=ReleaseFast -Dminimal=true
```

Features can be enabled individually on top of the preset:

```sh
zig build -Doptimize=ReleaseFast -Dminimal=true -Denable-compression=true
```

### Compile-time options

| Option                 | Default  | Description                                         |
|------------------------|----------|-----------------------------------------------------|
| `-Dminimal`            | `false`  | Disable optional features unless explicitly enabled |
| `-Denable-stats`       | `true`   | Traffic and packet counters                         |
| `-Denable-compression` | `true`   | Minecraft zlib packet compression                   |
| `-Denable-movement`    | `true`   | Idle, rotation, and bounded walking traffic         |
| `-Denable-broadcast`   | `true`   | Periodic chat messages                              |
| `-Denable-client-tick` | `true`   | 50 ms client tick packets                           |
| `-Denable-diagnostics` | `true`   | Join progress and disconnect diagnostics            |
| `-Dminecraft-version`  | `latest` | `latest` or an entry from the version catalog       |

## Run

Before a large run, raise the file descriptor limit:

```sh
ulimit -n 65536
```

Connect 1,000 clients to a local server:

```sh
zion --target 127.0.0.1:25565 --clients 1000
```

Run `zion --help` to see every runtime option.

### Transport targets

IPv6 addresses are accepted directly. Pass them without brackets, even though
Zion displays them in bracketed host-and-port form:

```sh
zion --target ::1 --clients 1000
```

Zion can also connect through a filesystem Unix stream socket:

```sh
zion --target unix:/run/minecraft.sock --clients 1000
```

The Minecraft handshake defaults to `localhost:25565` when using a Unix socket.
Override it independently of the transport endpoint when the server expects a
different virtual host:

```sh
zion \
  --target unix:/run/minecraft.sock \
  --handshake-host minecraft.example.com \
  --handshake-port 25565 \
  --clients 1000
```

The server or proxy must expose Minecraft over a filesystem Unix stream socket.
The CLI does not support Linux abstract namespace sockets.

### Workloads

This example adds bounded random walking and client tick packets:

```sh
zion \
  --target 127.0.0.1 \
  --clients 1000 \
  --movement walk \
  --movement-radius 100 \
  --client-tick
```

Zion spreads initial connections and periodic actions across their intervals to
avoid artificial bursts. Set `--connect-rate 0` to remove the connection ramp.

Chat load can grow much faster than the submission rate. For example, 1,000
clients using `--broadcast-ms 100` submit 10,000 messages per second. If the
server broadcasts every message to every connected player, that can become
roughly 10 million deliveries per second. Start with a multi-second interval
and reduce it gradually while monitoring server saturation.

Movement can also create substantial inbound traffic when the server relays
entity updates to nearby players. Monitor server tick rate alongside Zion's
traffic and reconnect statistics.

### Known core pack

By default Zion reports no known data packs during configuration. To advertise
the vanilla core pack matching the Minecraft version compiled into Zion, use:

```sh
zion --target 127.0.0.1 --clients 1000 --known-core-pack
```

Zion returns `minecraft:core:<version>` only when the server offers that exact
entry. A `latest` build uses the catalog's current GA release, while an explicit
`-Dminecraft-version` build uses the selected version. On a matching vanilla
server, this can reduce registry synchronization traffic. The option is
disabled by default.

## Development

### Tests and fuzzing

Run unit tests and replay the embedded fuzz regression corpus:

```sh
zig build test
```

Run Zig 0.17's builtin coverage-guided fuzzer with a bounded iteration count:

```sh
scripts/fuzz 100K
```

The equivalent direct command is `zig build fuzz --fuzz=100K`. Passing a bare
`--fuzz` runs continuously and starts Zig's fuzzing web UI. The `K`, `M`, and
`G` suffixes specify decimal iteration counts, not time limits.

Fuzz targets cover raw VarInt decoding, packet framing round trips, protocol
session packet draining, and stateful outbound queue transitions. Each target
has an embedded corpus, so checked-in reproductions also run as part of
`zig build test`.

The wrapper keeps its corpus under `.zig-cache/fuzz`. Repeated runs load inputs
discovered previously and retain newly interesting inputs. Each set of build
arguments has its own cache namespace, so a minimal build cannot cull inputs
needed by the full build. Set `ZION_FUZZ_CACHE` to choose another persistent
cache root.

The tested Zig development build can save a crashing input while returning
status 0 from a bounded run. `scripts/fuzz` detects that diagnostic and returns
failure while still using Zig's builtin fuzzer. The raw Smith input is written
to `f/crash` under the selected Zig cache. Reduce it if needed, then add the
reproducer to the target's `.corpus` list.

Useful feature matrix checks include:

```sh
zig build test -Dminimal=true
zig build test -Denable-compression=false
zig build test -Dminecraft-version=26.1.2
zig build test -Doptimize=ReleaseSafe
```

### Benchmarks

Run the scheduler microbenchmark with its default ReleaseFast build, two warmup
samples, and ten measured samples:

```sh
zig build bench
```

The runner excludes allocation and initial scheduling from each sample. Every
sample must execute the same action count and produce the same checksum, or the
benchmark fails. It reports all raw timings and uses the median as its primary
result. Pass workload options after `--`:

```sh
zig build bench -- --clients 50000 --actions 5000000 --interval-ms 50 --warmups 3 --samples 20
zig build bench -- --samples 20 --json
zig build bench -- --benchmark timer-idle --samples 20 --json
```

`--actions` is a minimum because timing wheel buckets are processed atomically.
JSON output includes the Zig version, optimization mode, workload parameters,
raw nanoseconds, action count, checksum, and summary.

Set `-Dbenchmark-optimize=ReleaseSafe` to change the benchmark optimization
mode. It defaults to `ReleaseFast` independently of the application's
`-Doptimize` setting.

For reproducible comparisons, use the same Zion revision, Zig build, and
workload arguments on an otherwise idle machine. Compare medians and retain the
JSON files so the raw samples and workload checksums remain auditable. Pinning
both runs to the same isolated CPU with `taskset -c <cpu>` and fixing the CPU
frequency governor can reduce environmental noise further.

The `timer-idle`, `timer-rotate`, and `timer-walk` benchmarks cover the complete
movement timer and packet queue path, with first-use allocation outside the
timed region. Use them to evaluate hot-kernel specialization. The default
`scheduler` benchmark isolates the timing wheel.

### Runtime architecture

The target is resolved and probed once per run, then each shard reuses one
precomputed socket address. Each shard owns one `io_uring`, its client state,
scheduler, fixed-file socket table, registered receive buffer group, and
protocol scratch buffers. Socket creation, options, connect, send, receive,
shutdown, and close all run through `io_uring`; fixed slot `N` belongs to client
`N` for the lifetime of that connection.

On kernels advertising receive/send bundles, one receive completion may cover
multiple contiguous 4 KiB provided buffers. Zion falls back to ordinary
multishot receives with 16 KiB buffers when the feature is unavailable.
Complete packets are parsed directly from those buffers; only fragmented packet
tails are copied into per-client storage.

Client handlers report explicit effects so ignored inbound packets do not touch
the timer wheel or write path. Cached broadcasts and client ticks are referenced
as immutable outbound segments instead of being copied into every client's
private buffer. Dynamic replies retain bounded per-client storage. Client state
is stored in structure-of-arrays columns using `std.MultiArrayList`.

## Disclaimer

Zion is intended only for load testing servers you own or have explicit
permission to test. It can generate enough connections and traffic to degrade
or crash a server and may also affect proxies, networks, or other shared
infrastructure in front of it. You are responsible for choosing safe limits,
monitoring the target, and complying with applicable laws and service-provider
rules. The authors are not responsible for misuse or damage caused by this
software.

## AI Disclaimer

This project was mostly created with AI, as this was meant as a tool designed for my use case. I found other tools were
too slow for my use case, or lacked features I wanted. If you require more features or don't like how something is
written, please fork it, I will likely not accept pull requests, or have the time to properly maintain this project.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
