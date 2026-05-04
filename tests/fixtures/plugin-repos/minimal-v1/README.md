# minimal plugin (fixture)

Minimal fixture for Story 13.4b build-pipeline smoke tests. Has a `container:`
block with no apt packages, no copy_from_builder paths (it lists the host's
own dev-toolchain image so the COPY layer is essentially free), an env var,
and a no-op install script that touches a marker file.
