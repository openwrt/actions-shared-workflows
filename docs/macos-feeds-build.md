# Feeds package test builds on macOS

`feeds-package-test-build-macos.yml` builds a feed's changed packages on a macOS
runner and runtime tests them on Linux, like `multi-arch-test-build.yml` does.
There is no OpenWrt SDK for macOS hosts, so `macos-toolchain.yml` builds its
parts from the current snapshot every 6 hours, publishes them to S3, and every
pull request restores them.

## Using it in a feed

```yaml
jobs:
  test-macos:
    name: Feeds Package Test Build macOS
    uses: openwrt/actions-shared-workflows/.github/workflows/feeds-package-test-build-macos.yml@main
```

It can run next to the Linux job in the same workflow. Every input is optional.

| Input | Default | Description |
| --- | --- | --- |
| `matrix` | `aarch64_generic` runtime tested, `arm_cortex-a9_vfpv3-d16` not | JSON build matrix, SDK parts exist only for these two architectures |
| `packages` | the changed packages, else the feed's default set | space-separated list |
| `branch` | the branch the run is for | OpenWrt branch, `main`, `master` or `openwrt-X.Y` |
| `feed_repository`, `feed_ref` | the calling repository and its ref | another feed to check out |
| `enable_generic_tests`, `force_generic_tests` | `true` | as in the Linux workflow |
| `sdk_url` | the public bucket | where the manifests and archives are served |

What to expect, and where it differs from the Linux job:

- It builds at the snapshot the producer last published, which lags behind the
  SDK the Linux job downloads.
- A branch the producer does not publish fails the run, so limit the job with
  `if: github.base_ref == 'master'` when the feed targets other branches too.
- Packages that need the kernel are skipped with a warning when no kernel is
  published for the snapshot, and BPF packages use the runner's `llvm@20`.
- Archives are checked against the SHA-256 the manifest names before they are
  extracted. The manifest is not signed, so that catches a broken download,
  not a bucket serving something else.
- A package skipped for an unsupported architecture or a missing kernel is not
  a tested package. The build log names every one it skipped.

## Setting up the producer

It needs four secrets in this repository, and stops at once without them. The
ones of the same name in `openwrt/openwrt` are not visible here.
`CCACHE_S3_ENDPOINT` is the S3 API endpoint, the rest are `CCACHE_S3_BUCKET`,
`CCACHE_S3_ACCESS_KEY` and `CCACHE_S3_SECRET_KEY`. Only the publish step gets
them, and the producer builds no code from feeds.

- The bucket must be publicly readable at `sdk_url`. The producer checks that
  every archive it uploads can be read there.
- `MACOS_SDK_URL` overrides `sdk_url` for this repository's own callers only, so
  moving the bucket also means changing the default in the consumer.
- Do not expire objects by age. An archive stays current as long as its snapshot
  is the newest of its branch, which can be weeks on a release branch. Prune by
  hand once no manifest names an archive.
- Dispatching it with `force` rebuilds a snapshot that is already published,
  which is also how a kernel that failed to assemble gets another try.

`manual-test-feeds-macos.yml` runs the consumer by hand against any feed.
