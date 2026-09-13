# Feeds package test builds on macOS

Two workflows provide the macOS counterpart of `multi-arch-test-build.yml`.
There is no prebuilt OpenWrt SDK container for macOS, so the host tools and the
cross toolchain are built once, out of band, and every pull request run only
restores them and builds packages – the same split the Linux workflow gets from
`openwrt/gh-action-sdk`.

| Workflow | Role | Runs | Secrets |
| --- | --- | --- | --- |
| `macos-toolchain.yml` → `reusable_macos-toolchain.yml` | producer: builds `tools/install` + `toolchain/install` and publishes them | nightly, `workflow_dispatch` | S3 write |
| `feeds-package-test-build-macos.yml` | consumer: restores the published toolchain and builds the changed feed packages | `workflow_call` from feed repositories | none |

Restoring a published toolchain takes about a minute. A pull request run is
dominated by the feed index, the host packages every package build needs (the
package manager host tools) and the package builds themselves. The producer
skips its multi-hour build whenever the published toolchain already matches the
current core tree, so most nightly runs finish in a few minutes.

## Producer: `macos-toolchain.yml`

Runs nightly for `master`, `openwrt-25.12` and `openwrt-24.10`, one branch at a
time, only in the `openwrt` organisation; `workflow_dispatch` (inputs `branch`
and `force`) works everywhere. Only `main`, `master` and `openwrt-X.Y` are
accepted, because those are the only branches the consumer looks up. For every
architecture in the matrix it:

1. clones `openwrt/openwrt` at the branch tip and hashes the trees the build
   depends on: `tools/`, `toolchain/`, `include/`, `config/`, `Config.in`,
   `Makefile`, `rules.mk` for the host tools, plus the target's
   `target/linux/<board>/Makefile` (kernel version) and
   `target/linux/<board>/<subtarget>/target.mk` (CPU type) for the toolchain;
2. reads the published manifest and stops if it already matches those hashes
   and the runner image version;
3. otherwise builds `make tools/install` and `make toolchain/install` natively
   and uploads, in this order:

   ```
   macos-tools-<branch>-<core_sha>.tar.zst                  staging_dir/host
   macos-toolchain-<arch>-<branch>-<toolchain_sha>.tar.zst  staging_dir/toolchain-* and target-*
   macos-sdk-<branch>-<arch>.json                           manifest, written last
   ```

   The manifest records the exact `openwrt_commit` the archives were built
   from:

   ```json
   {
     "openwrt_commit": "…",
     "core_sha": "…",
     "toolchain_sha": "…",
     "image_version": "20260831.0337.3",
     "tools": "macos-tools-master-….tar.zst",
     "toolchain": "macos-toolchain-aarch64_generic-master-….tar.zst"
   }
   ```

The upload only runs for `schedule` and `workflow_dispatch` events. The S3
credentials are written to a temporary `mc` configuration that exists only
during the manifest check and the upload, never while the core build systems
run, and the producer executes no code from any feed.

Without S3 credentials the producer still builds (useful as a smoke test of the
buildroot on macOS) but publishes nothing.

### Secrets

The trigger workflow maps the repository/organisation secrets to the reusable
workflow, accepting either the `ccache_s3_*` names used by `packages.yml` and
`kernel.yml` or plain `s3_*`:

| Secret | Description |
| --- | --- |
| `ccache_s3_endpoint` / `s3_endpoint` | S3 API endpoint, without bucket or path, e.g. `https://<account-id>.r2.cloudflarestorage.com` |
| `ccache_s3_bucket` / `s3_bucket` | bucket name |
| `ccache_s3_access_key` / `s3_access_key` | access key ID |
| `ccache_s3_secret_key` / `s3_secret_key` | secret access key |

Old archives are never deleted; superseded ones can be pruned by hand.

## Consumer: `feeds-package-test-build-macos.yml`

Reusable workflow for feed repositories, mirroring the inputs and the artifact
layout of `multi-arch-test-build.yml`. It can be called from the same workflow
as the Linux job; its concurrency group is distinct.

```yaml
jobs:
  test-macos:
    uses: openwrt/actions-shared-workflows/.github/workflows/feeds-package-test-build-macos.yml@main
```

| Input | Default | Description |
| --- | --- | --- |
| `matrix` | two arches (`aarch64_generic`, `arm_cortex-a9_vfpv3-d16`) | JSON build matrix, same format as the Linux workflow |
| `packages` | changed packages, else the feed's default set | explicit space-separated package list |
| `feed_repository` | the checked-out workspace | `owner/name` of a feed to clone instead (self-tests) |
| `branch` | derived from the pull request base branch | OpenWrt branch |
| `sdk_url` | `https://s3-ccache.openwrt-ci.ansuel.com` | base URL that serves the manifests and archives (public read) |

The archives are fetched anonymously, so the bucket (or a CDN in front of it)
must be publicly readable at `sdk_url`. If no manifest exists for the branch
and architecture the job fails immediately with a pointer to the producer –
it never falls back to building the toolchain itself. Pull requests against a
branch the producer does not publish (for example an end-of-life release) fail
the same way; callers can limit the job with
`if: github.base_ref == 'master'` or dispatch the producer for that branch.

For every package the job performs the checks `openwrt/gh-action-sdk` performs
on Linux: `feeds install`, `download`, `check` with `PKG_HASH` validation,
`refresh` with a dirty-patch check, `shfmt -sr -s` on `files/*.init`, then
`compile` (stopping at the first failure, like the SDK) and an unsigned
`package/index`. Packages are skipped with a warning when they are not
available for the architecture, or when they depend on the Linux kernel build
(kernel modules and everything that pulls one in): the kernel is not prebuilt
on macOS. The job fails if the restored host tools or toolchain get rebuilt,
since that means the published archives do not match. Runtime tests need Linux
containers and are not run.

## Self-test from this repository

`manual-test-feeds-macos.yml` (`workflow_dispatch` only) runs the consumer
against `openwrt/packages` – or any `feed_repository` – with an optional
package list. Set the repository variable `MACOS_SDK_URL` to point the self-test
at your own bucket; otherwise it uses the default `sdk_url`.
