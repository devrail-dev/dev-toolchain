# Fixture: kotlin-via-plugin

Vendored snapshot of `github.com/devrail-dev/devrail-plugin-kotlin` v1.0.0,
used by `tests/test-kotlin-plugin-extraction.sh` to run the resolver,
loader, and validator against the kotlin reference plugin without a
network fetch.

## Refresh procedure

When the upstream plugin cuts a new tag:

```sh
cd ~/Work/github.com/devrail-dev/devrail-plugin-kotlin
git checkout vX.Y.Z

cd ~/Work/github.com/devrail-dev/dev-toolchain
cp ../devrail-plugin-kotlin/plugin.devrail.yml tests/fixtures/kotlin-via-plugin/
cp ../devrail-plugin-kotlin/install.sh tests/fixtures/kotlin-via-plugin/
```

Then re-run the smoke test and update the version pin in the test if
the manifest's `version` field changed:

```sh
bash tests/test-kotlin-plugin-extraction.sh
```

## Why a vendored copy

- Hermetic — no network access at test time
- Reproducible — the test pins to a known plugin version
- Independent of GitHub uptime / rate limits during CI

## What's NOT covered by this fixture

The fixture lets us exercise the manifest validator, resolver, and
loader against a real plugin manifest. It does NOT exercise the full
docker-build of `devrail-local:<hash>` — that pulls real ktlint, detekt,
and gradle from upstream and takes ~5 minutes. Maintainers run the full
build manually:

```sh
cd ~/Work/github.com/devrail-dev/devrail-plugin-kotlin
# Create a tiny Kotlin sample workspace pointing back at this checkout
# via a file:// URL, then `make plugins-update && make check` and
# observe the extended image build + Kotlin tooling run.
```

This trade-off mirrors what we did for the `minimal-v1` fixture — keep
CI fast, maintainers do the heavy validation by hand.
