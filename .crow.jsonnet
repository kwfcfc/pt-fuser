// Crow CI workflow for pt-fuser.
//
// Build target: linux/amd64. We officially support Ubuntu 22.04, Ubuntu 24.04,
// Debian 12, and Debian 13.
//
// Currently we only build on Ubuntu 22.04 (glibc 2.35) — the oldest of the
// four targets. Because glibc is forward-compatible, a binary linked there
// works on all of the newer targets. The other matrix rows are kept in this
// file (commented out) so we can flip back to a per-distro build if we ever
// need native packages (.deb/.rpm) tied to each release's package metadata.

local distros = [
  { name: 'ubuntu-22.04', image: 'ubuntu:22.04' },
  // { name: 'ubuntu-24.04', image: 'ubuntu:24.04' },
  // { name: 'debian-12',    image: 'debian:bookworm' },
  // { name: 'debian-13',    image: 'debian:trixie' },
];

// Packages required by the workspace:
//   - build-essential, pkg-config: standard C toolchain + linker
//   - clang, libclang-dev, llvm-dev: bindgen needs libclang at build time
//   - linux-libc-dev: kernel uapi headers reachable from clang's -isystem
//   - ca-certificates, curl, git: rustup bootstrap + crates.io fetch
local aptPackages = [
  'ca-certificates',
  'curl',
  'git',
  'build-essential',
  'pkg-config',
  'clang',
  'libclang-dev',
  'llvm-dev',
  'linux-libc-dev',
];

local installDeps = [
  'export DEBIAN_FRONTEND=noninteractive',
  'apt-get update',
  'apt-get install -y --no-install-recommends ' + std.join(' ', aptPackages),
];

// Rust toolchain version is pinned in rust-toolchain.toml at the repo root
// (single source of truth). We bootstrap via rustup rather than the distro
// rust package because Ubuntu 22.04 / Debian 12 don't ship a recent-enough
// rustc for the pinned version (and edition 2024 requires >= 1.85 anyway).
//
// `--default-toolchain none` skips downloading a placeholder toolchain at
// rustup-init time; the subsequent `rustup show` reads rust-toolchain.toml
// from the workspace and installs exactly that version with the minimal
// profile — one toolchain download, not two.
//
// Some Crow agent backends mount /root as a named volume, so a half-finished
// rustup from a previous run can leave a stale /root/.rustup that confuses
// the next run (you will see "It looks like you have an existing rustup
// settings file"). Wipe it before reinstalling.
//
// If the agent is on a slow link to static.rust-lang.org (typical for
// China-hosted runners), uncomment the RUSTUP_*_SERVER lines to use the
// USTC mirror — speeds the toolchain download up by 10-100x.
local installRust = [
  'rm -rf "$HOME/.rustup" "$HOME/.cargo"',
  "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs " +
    '| sh -s -- -y --profile minimal --default-toolchain none --no-modify-path',
  '. "$HOME/.cargo/env"',
  // Triggers install of the toolchain pinned in rust-toolchain.toml.
  'rustup show',
  'rustc --version',
  'cargo --version',
];

local build = [
  '. "$HOME/.cargo/env"',
  'cargo build --release --workspace --locked',
  // ignore the test step
  // 'cargo test  --release --workspace --locked',
];

// Collect everything that downstream consumers actually need:
//   - libtransform_trace.so (the dlfilter loaded by `perf script`)
//   - the workspace binaries (histogram, merge, convert_perfetto)
local archive = [
  'mkdir -p artifacts/${TARGET}',
  'cp target/release/libtransform_trace.so artifacts/${TARGET}/',
  'for bin in histogram merge convert_perfetto; do ' +
    'if [ -x "target/release/$bin" ]; then cp "target/release/$bin" "artifacts/${TARGET}/"; fi; ' +
    'done',
  'ls -la artifacts/${TARGET}/',
];

// Shared packaging — both the manual R2 upload and the tag-driven
// GitHub Release step consume `dist/`. REF differs by event so manual
// and tag builds can never collide on filename.
//
// pipefail: without this, tar failing inside `tar | zstd` is silently
// ignored (zstd happily writes an empty 13B frame) and we ship a corrupt
// archive while the step reports green.
local package_ = [
  'set -eu -o pipefail',
  'apk add --no-cache tar zstd',

  'if [ "$CI_PIPELINE_EVENT" = "tag" ]; then',
  '  REF="$CI_COMMIT_TAG"',
  'else',
  '  REF="manual-${CI_PIPELINE_NUMBER}-${CI_COMMIT_SHA_SHORT}"',
  'fi',

  'TARBALL="pt-fuser-$REF-${TARGET}-linux-amd64.tar.zst"',
  'mkdir -p dist',
  'tar -C artifacts -cf - "${TARGET}" | zstd -T0 -19 -f -o "dist/$TARBALL"',
  '( cd dist && sha256sum "$TARBALL" > "$TARBALL.sha256" )',
  'ls -la dist/',
];

{
  // The top-level workflow name is registered BEFORE matrix expansion, so
  // ${NAME} would not be substituted here — Crow's UI auto-labels each
  // matrix variant with its `NAME` value as a sub-row instead.
  name: 'pt-fuser build',

  // Only run on manual dispatch or when a tag is pushed.
  // Push/PR events do NOT trigger this workflow.
  when: [
    { event: ['manual', 'tag'] },
  ],

  // Pin scheduling to linux/amd64 agents. Unlike step-level `when: platform:`
  // (which silently filters the step out when it doesn't match), `labels:`
  // is an agent-selection constraint: if no matching agent is available the
  // pipeline stays pending instead of being aborted.
  labels: {
    platform: 'linux/amd64',
    tier: 'local',
  },

  // 4-way matrix, one entry per target distro. All AMD64.
  matrix: {
    include: [
      { NAME: d.name, TARGET: d.name, IMAGE: d.image }
      for d in distros
    ],
  },

  // Single consolidated step per matrix entry.
  // Crow gives each step a fresh container, so apt/rustup state would not
  // survive across step boundaries; keeping it in one step is simpler than
  // relocating CARGO_HOME/RUSTUP_HOME into the shared workspace.
  steps: [
    {
      name: 'build-${NAME}',
      image: '${IMAGE}',
      environment: {
        CARGO_TERM_COLOR: 'always',
        RUST_BACKTRACE: '1',
      },
      commands: installDeps + installRust + build + archive,
    },
    // Shared packaging — produces dist/<tarball> + dist/<tarball>.sha256
    // for both downstream upload steps. Small alpine image so the matrix
    // doesn't pull 4 different ubuntu/debian images just to repackage.
    {
      name: 'package-${TARGET}',
      image: 'alpine:3.23',
      when: [{ event: ['manual', 'tag'] }],
      commands: package_,
    },
    // Manual-only: push to Cloudflare R2 via the woodpecker s3 plugin.
    // R2 is S3-compatible; `endpoint` + `region: auto` + `path_style` is
    // the standard incantation.
    {
      name: 'r2-upload-${TARGET}',
      image: 'docker.io/woodpeckerci/plugin-s3',
      when: [{ event: 'manual' }],
      settings: {
        endpoint: { from_secret: 'r2_endpoint' },
        access_key: { from_secret: 'r2_access_key_id' },
        secret_key: { from_secret: 'r2_secret_access_key' },
        bucket: { from_secret: 'r2_bucket' },
        region: 'auto',
        path_style: true,
        source: 'dist/*',
        strip_prefix: 'dist/',
        target: '/pt-fuser/manual/${CI_PIPELINE_NUMBER}-${CI_COMMIT_SHA_SHORT}/${TARGET}/',
      },
    },
    // Only runs on tag pushes. Each matrix instance uploads its own
    // distro-specific tarball + sha256 to the same GitHub Release.
    // The release plugin is idempotent on the tag (no view-or-create
    // race like the old gh-cli flow), and `file-exists` defaults to
    // overwrite — equivalent to `gh release upload --clobber`.
    // Requires a Crow secret named `github_token` with a PAT that has
    // `contents: write` on the target repo.
    {
      name: 'release-${NAME}',
      image: 'docker.io/woodpeckerci/plugin-release',
      when: [{ event: 'tag' }],
      settings: {
        api_key: { from_secret: 'github_token' },
        files: ['dist/*'],
        title: '${CI_COMMIT_TAG}',
        note: 'Automated release for ${CI_COMMIT_TAG} from Crow CI',
      },
    },
  ],
}
