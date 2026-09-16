# Feeds package test builds on macOS

`feeds-package-test-build-macos.yml` builds the changed packages of a feed on
a macOS runner, with the steps, artifacts and runtime tests of
`multi-arch-test-build.yml`. There is no OpenWrt SDK for macOS hosts, so
`macos-toolchain.yml` builds its parts from the current snapshot and publishes
them to S3, and every pull request job restores them.

| Workflow | Role | Runs |
| --- | --- | --- |
| `macos-toolchain.yml` | builds the SDK parts and publishes them | every 6 hours, `workflow_dispatch` |
| `feeds-package-test-build-macos.yml` | restores the SDK parts, builds the feed packages and runtime tests them on Linux | `workflow_call` from feed repositories |

## Using it in a feed

```yaml
jobs:
  test-macos:
    name: Feeds Package Test Build macOS
    uses: openwrt/actions-shared-workflows/.github/workflows/feeds-package-test-build-macos.yml@main
```

It can run next to the Linux job in the same workflow.

| Input | Default | Description |
| --- | --- | --- |
| `enable_generic_tests` | `true` | run the generic runtime tests |
| `force_generic_tests` | `true` | run the generic runtime tests even for packages with a `test.sh` |
| `matrix` | `aarch64_generic` (runtime tested), `arm_cortex-a9_vfpv3-d16` | JSON build matrix in the format of the Linux workflow, SDK parts are only published for these two architectures |
| `packages` | changed packages, else the feed's default set | explicit space-separated package list |
| `feed_repository` | the calling repository | `owner/name` of a feed to check out instead |
| `branch` | the pull request base branch | OpenWrt branch, with `feed_repository` also the feed ref |
| `sdk_url` | `https://s3-ccache.openwrt-ci.ansuel.com` | public URL serving the manifests and archives |

Differences from the Linux job:

- It builds at the snapshot revision the producer last published, which can
  lag behind the SDK the Linux job downloads.
- When no kernel is published for the snapshot, packages that need the kernel
  are skipped with a warning.
- The runtime tests run in a follow-up `ubuntu-latest` job, because macOS
  runners have no Docker. It runs the steps of the Linux workflow for every
  matrix entry with `runtime_test` whose macOS build succeeded.
- BPF packages are built with the runner's Homebrew `llvm@20` instead of the
  SDK's llvm-bpf.
- A pull request against a branch the producer does not publish fails when
  the SDK parts are restored. Callers can limit the job with
  `if: github.base_ref == 'master'`.

## Producer

`macos-toolchain.yml` runs every 6 hours for `master` and `openwrt-25.12`, one
branch at a time, only in the `openwrt` organisation. It
can be dispatched for one branch, or for all of them with an empty `branch`,
and with `force` to rebuild a snapshot that is already published.

For each architecture it downloads the snapshot's `sha256sums`, verifies its
signature with the OpenWrt keys, and stops when the manifest already names that
snapshot revision. Otherwise it checks the revision out on a case-sensitive
volume, builds these archives and publishes them:

| Archive | Contents |
| --- | --- |
| `macos-sdk-<branch>-<arch>-<revision>.tar.zst` | host tools, cross toolchain and, on apk branches, the apk host tools |
| `macos-kernel-<branch>-<arch>-<revision>.tar.zst` | the kernel tree kernel modules are built against, prepared on macOS from the kernel of the snapshot SDK |

The manifest `macos-sdk-<branch>-<arch>.json` is published last. It names the
snapshot revision, the archives and the build configuration, which is the
snapshot's `config.buildinfo` with the SDK's package signing, the runner's LLVM
for BPF and without `CONFIG_BUILDBOT`.

A kernel that cannot be assembled does not fail the run. The manifest is then
published without a kernel, and the kernel is tried again with the next
snapshot or when the workflow is dispatched with `force`.

### Setup

The producer needs these secrets in this repository. The secrets of the same
name in `openwrt/openwrt` are not available here. Without them it fails at
once.

| Secret | Description |
| --- | --- |
| `CCACHE_S3_ENDPOINT` | S3 API endpoint, e.g. `https://<account-id>.r2.cloudflarestorage.com` |
| `CCACHE_S3_BUCKET` | bucket name |
| `CCACHE_S3_ACCESS_KEY` | access key ID |
| `CCACHE_S3_SECRET_KEY` | secret access key |

Only the publish step gets them, and the producer builds no code from feeds.
The bucket must be publicly readable at `sdk_url`, which is the repository
variable `MACOS_SDK_URL` or `https://s3-ccache.openwrt-ci.ansuel.com`. The
producer checks that every archive it uploads can be read there.

Old archives are not deleted and can be pruned by hand when no manifest names
them. An archive stays named as long as its snapshot is the newest of its
branch, which can be weeks on a release branch, so a lifecycle rule that
expires objects by age can break the consumer. The producer does not notice a
deleted archive. It publishes it again only with the next snapshot, or when it
is dispatched with `force`.

## Self-test

`manual-test-feeds-macos.yml` (`workflow_dispatch` only) runs the consumer
against `openwrt/packages` or any `feed_repository`, with an optional package
list and branch.
