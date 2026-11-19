# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form, PREFERRED) — builds ON TOP of the org C/C++ base
# image (ghcr.io/savantenvs/base). The base already provides debian + clang/llvm +
# libFuzzer/afl++ + the identities + the build-contract ENV, so this only adds the
# per-commit build (built on top of the prebuilt base, rather than building the toolchain in-image).
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t mytag .

# The org base, pinned to a fixed DATE-tagged base (YYYYMMDD; shared by all integrations
# minted against it). Use the current dated tag; pin by digest in production: ...base@sha256:<digest>.
FROM ghcr.io/savantenvs/base:20261023

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV — an
# empty value breaks clang ("must be a non-negative decimal integer") both here and for
# any in-image rebuild. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# To change it for a build (e.g. ASan-only, or add MSan): --build-arg SANITIZER_FLAGS="...".
# Declare it WITHOUT a default (no '='): an undefaulted ARG lets the base ENV flow through to
# build.sh when not passed, and an explicit --build-arg overrides it. (An empty default — `=` —
# would instead shadow the base ENV and silently wipe the sanitizers.)
ARG SANITIZER_FLAGS
# Coverage (optional, off by default): instrument the TEST build to measure how much of the project
# the suite exercises — --build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping".
# Empty by default (no effect on the normal oracle build); build.sh appends it to the test build only.
ARG COVERAGE_FLAGS=
# Build parallelism (optional). build.sh falls back to nproc when unset: --build-arg MAYHEM_JOBS=8
ARG MAYHEM_JOBS=

# Extra apt packages: libzstd-dev (static libzstd.a; Debian ships zstd 1.5.7, the version upstream
# pins in cmake/vendor.cmake).
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends libzstd-dev \
 && rm -rf /var/lib/apt/lists/*

# The rest of what upstream's cmake/vendor.cmake downloads with CPM at configure time, pinned to the
# same versions and cached under /opt/toolchains/deps (SPEC §6.2 item 19) so build.sh runs offline:
#   capstone 6.0.0-Alpha11 (static lib, same options as vendor.cmake), PPQSort 1.0.6 (header-only,
#   with upstream's two cmake/ppqsort-*.patch applied, as CPM does), nlohmann/json 3.12.0 (header-only).
ARG CAPSTONE_VER=6.0.0-Alpha11
ARG CAPSTONE_SHA256=635bc456097c3cfe69da28bfeb196a5e1d0b7631accb2ddaf7cd00cb587957bb
ARG PPQSORT_VER=1.0.6
ARG PPQSORT_SHA256=12d9c05363fa3d36f4916a78f1c7e237748dfe111ef44b8b7a7ca0f3edad44da
ARG JSON_VER=3.12.0
ARG JSON_SHA256=4b92eb0c06d10683f7447ce9406cb97cd4b453be18d7279320f7b2f025c10187
RUN d=/opt/toolchains/deps/capstone-${CAPSTONE_VER} && mkdir -p "$d/src" /tmp/dep-build \
 && curl -fsSL -o /tmp/dep.tgz https://github.com/capstone-engine/capstone/archive/refs/tags/${CAPSTONE_VER}.tar.gz \
 && echo "${CAPSTONE_SHA256}  /tmp/dep.tgz" | sha256sum -c - \
 && tar -xzf /tmp/dep.tgz --strip-components=1 -C "$d/src" \
 && cmake -S "$d/src" -B /tmp/dep-build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS="-g -gdwarf-3" -DCMAKE_INSTALL_PREFIX="$d" -DBUILD_SHARED_LIBS=OFF \
      -DCAPSTONE_BUILD_SHARED_LIBS=OFF -DCAPSTONE_BUILD_STATIC_LIBS=ON -DCAPSTONE_BUILD_CSTOOL=OFF \
      -DCAPSTONE_BUILD_LEGACY_TESTS=OFF -DCAPSTONE_INSTALL=ON -DCAPSTONE_X86_ATT_DISABLE=ON \
      -DCAPSTONE_ALPHA_SUPPORT=OFF -DCAPSTONE_ARC_SUPPORT=OFF -DCAPSTONE_HPPA_SUPPORT=OFF \
      -DCAPSTONE_LOONGARCH_SUPPORT=OFF -DCAPSTONE_M680X_SUPPORT=OFF -DCAPSTONE_M68K_SUPPORT=OFF \
      -DCAPSTONE_MIPS_SUPPORT=OFF -DCAPSTONE_MOS65XX_SUPPORT=OFF -DCAPSTONE_PPC_SUPPORT=OFF \
      -DCAPSTONE_SPARC_SUPPORT=OFF -DCAPSTONE_SYSTEMZ_SUPPORT=OFF -DCAPSTONE_XCORE_SUPPORT=OFF \
      -DCAPSTONE_TRICORE_SUPPORT=OFF -DCAPSTONE_TMS320C64X_SUPPORT=OFF -DCAPSTONE_EVM_SUPPORT=OFF \
      -DCAPSTONE_WASM_SUPPORT=OFF -DCAPSTONE_BPF_SUPPORT=OFF -DCAPSTONE_RISCV_SUPPORT=OFF \
      -DCAPSTONE_SH_SUPPORT=OFF -DCAPSTONE_XTENSA_SUPPORT=OFF \
 && cmake --build /tmp/dep-build -j"$(nproc)" && cmake --install /tmp/dep-build \
 && rm -rf /tmp/dep-build /tmp/dep.tgz "$d/lib/cmake" "$d/lib/pkgconfig" && rm -f "$d"/lib/*.so* \
 && chmod -R a+rX "$d"
COPY --chown=0:0 cmake/ppqsort-nodebug.patch cmake/ppqsort-semaphore.patch /tmp/ppqsort-patches/
RUN d=/opt/toolchains/deps/PPQSort-${PPQSORT_VER} && mkdir -p "$d/src" \
 && curl -fsSL -o /tmp/dep.tgz https://github.com/GabTux/PPQSort/archive/refs/tags/v${PPQSORT_VER}.tar.gz \
 && echo "${PPQSORT_SHA256}  /tmp/dep.tgz" | sha256sum -c - \
 && tar -xzf /tmp/dep.tgz --strip-components=1 -C "$d/src" \
 && for p in /tmp/ppqsort-patches/ppqsort-nodebug.patch /tmp/ppqsort-patches/ppqsort-semaphore.patch; do \
      patch -d "$d/src" -p1 < "$p"; done \
 && rm -rf /tmp/dep.tgz /tmp/ppqsort-patches && chmod -R a+rX "$d"
RUN d=/opt/toolchains/deps/json-${JSON_VER} && mkdir -p "$d/src" \
 && curl -fsSL -o /tmp/dep.tgz https://github.com/nlohmann/json/archive/refs/tags/v${JSON_VER}.tar.gz \
 && echo "${JSON_SHA256}  /tmp/dep.tgz" | sha256sum -c - \
 && tar -xzf /tmp/dep.tgz --strip-components=1 -C "$d/src" \
 && rm -f /tmp/dep.tgz && chmod -R a+rX "$d"
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git
# history) is copied to /mayhem as `mayhem`; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Anything a Dockerfile step materializes into the tree (downloaded fixtures, generated headers,
# vendored deps) MUST be committed or (re)created by build.sh: rlenv's patch grader runs
# `git clean -ffdX` before every graded build, so a gitignored, untracked file is gone by then and
# every honest patch scores zero (SPEC §6.2 item 16; verify-repo.sh checks it).
#
# OPTIONAL compile-cache pre-fill (SPEC §6.2 item 18). Bases minted with /opt/mayhem/ccache/prefill
# run the build under rlenv's pinned ccache, so the patch grader's first (otherwise cold) rebuild is
# warm — this is what keeps large C/C++ targets inside the build time limit. Older bases fall back to
# the plain build; a missing or stale pre-fill only costs a cold cache. Never enable ccache in
# build.sh or via ENV/PATH, and keep the compiler resolving by name (CC=clang) or nothing is cached.
RUN if [ -x /opt/mayhem/ccache/prefill ]; then /opt/mayhem/ccache/prefill bash mayhem/build.sh; \
    else bash mayhem/build.sh; fi

# Run the project's functional tests at build time IF the repo ships them (mayhem/test.sh is
# optional — omit it only when the repo has no tests meaningful for RL). A failing suite fails the
# image build, so the commit image is guaranteed to build AND pass its own tests.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
