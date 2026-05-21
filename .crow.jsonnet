// Crow CI workflow for pt-fuser.
//
// Build matrix: four AMD64 Linux distributions.
// We do NOT add an architecture axis because every target is linux/amd64.
// We DO build per-distro so each .so/binary is linked against the right
// glibc / libclang / linux-libc-dev for that distro.

local distros = [
  { name: 'ubuntu-22.04', image: 'ubuntu:22.04' },
  { name: 'ubuntu-24.04', image: 'ubuntu:24.04' },
  { name: 'debian-12',    image: 'debian:bookworm' },
  { name: 'debian-13',    image: 'debian:trixie' },
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

// Edition 2024 requires rustc >= 1.85, which is newer than what Ubuntu 22.04
// and Debian 12 ship. Use rustup with the latest stable toolchain instead of
// the distro package.
local installRust = [
  "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs " +
    '| sh -s -- -y --profile minimal --default-toolchain stable',
  '. "$HOME/.cargo/env"',
  'rustc --version',
  'cargo --version',
];

local buildAndTest = [
  '. "$HOME/.cargo/env"',
  'cargo build --release --workspace --locked',
  'cargo test  --release --workspace --locked',
];

// Collect everything that downstream consumers actually need:
//   - libtransform_trace.so (the dlfilter loaded by `perf script`)
//   - the workspace binaries (histogram, merge, convert_perfetto)
local archive = [
  'mkdir -p artifacts/${NAME}',
  'cp target/release/libtransform_trace.so artifacts/${NAME}/',
  'for bin in histogram merge convert_perfetto; do ' +
    'if [ -x "target/release/$bin" ]; then cp "target/release/$bin" "artifacts/${NAME}/"; fi; ' +
    'done',
  'ls -la artifacts/${NAME}/',
];

// Statically-linked gh CLI release; lets us avoid distro repo pinning.
local ghVersion = '2.65.0';
local installGh = [
  'apt-get install -y --no-install-recommends curl ca-certificates tar',
  'curl -fsSL "https://github.com/cli/cli/releases/download/v' + ghVersion +
    '/gh_' + ghVersion + '_linux_amd64.tar.gz" -o /tmp/gh.tgz',
  'tar -xzf /tmp/gh.tgz -C /tmp',
  'install -m 0755 "/tmp/gh_' + ghVersion + '_linux_amd64/bin/gh" /usr/local/bin/gh',
  'gh --version',
];

// Race note: each matrix instance attempts `gh release create`. Whichever
// gets there first wins; the others get a 422 "already_exists" and we
// swallow it. All instances then upload their own tarball with --clobber.
local releaseUpload = [
  'TAG="${CI_COMMIT_TAG}"',
  'TARBALL="pt-fuser-${TAG}-${NAME}-linux-amd64.tar.gz"',
  'tar -C artifacts -czf "$TARBALL" "${NAME}"',
  'sha256sum "$TARBALL" > "$TARBALL.sha256"',
  'gh release view "$TAG" --repo "$CI_REPO" >/dev/null 2>&1 || ' +
    'gh release create "$TAG" --repo "$CI_REPO" ' +
    '--title "$TAG" --notes "Automated release for $TAG" || true',
  'gh release upload "$TAG" "$TARBALL" "$TARBALL.sha256" ' +
    '--repo "$CI_REPO" --clobber',
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
  },

  // 4-way matrix, one entry per target distro. All AMD64.
  matrix: {
    include: [
      { NAME: d.name, IMAGE: d.image }
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
      commands: installDeps + installRust + buildAndTest + archive,
    },
    // Only runs on tag pushes. Each matrix instance uploads its own
    // distro-specific tarball + sha256 to the same GitHub Release.
    // Requires a Crow secret named `github_token` with a PAT that has
    // `contents: write` on the target repo.
    {
      name: 'release-${NAME}',
      image: '${IMAGE}',
      when: [{ event: 'tag' }],
      environment: {
        DEBIAN_FRONTEND: 'noninteractive',
        GH_TOKEN: { from_secret: 'github_token' },
      },
      commands: ['apt-get update'] + installGh + releaseUpload,
    },
  ],
}
