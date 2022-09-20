# Summary

This repo just has a one-off script and patches for `cloudigrade` to test `cloudigrade`'s performance when built over UBI8 versus UBI9. The test specifically focuses on logging because we observed that Watchtower with `use_queues=False` has catastrophically bad performance when running on UBI9 whereas it had acceptable (but still *not great*) performance on UBI8.

# Usage

This repo has @infinitewarp's personal one-off script designed and tested only on his local system and may not work on yours. Caveat emptor. Hic sunt dracones.

## Assumptions/prereqs

1. recent cloudigrade repo lives at `~/projects/cloudigrade`
2. script to activate cloudigrade lives at `~/bin/cloudigrade.sh`
3. script to export ephemeral-specific env vars lives at `~/.env-files/ephemeral`
4. `brew install moreutils openshift-cli coreutils httpie`
5. Docker or Podman is installed and running.
6. Docker or Podman is logged in with quay.io; it will need to push images.
7. `oc` CLI is logged in with ephemeral cluster. [Request token](https://oauth-openshift.apps.c-rh-c-eph.8p0c.p1.openshiftapps.com/oauth/token/request).
8. Connect to the Red Hat VPN.

## Execution

To build and run on the last UBI8 ref before the first UBI9 upgrade:

```sh
UBI=8 ./scripts/ubi-perf-test.sh
```

To build and run on the first ref with UBI9:

```sh
UBI=9 ./scripts/ubi-perf-test.sh
```

To build and run on an arbitrary ref assuming UBI8 (like the latest master):

```sh
git -C ~/projects/cloudigrade checkout master && \
git -C ~/projects/cloudigrade pull && \
BASE_REF=$(git -C ~/projects/cloudigrade rev-parse --short HEAD)

UBI=8 BASE_REF="${BASE_REF}" ./scripts/ubi-perf-test.sh
```

To build and run on an arbitrary ref (like the latest master) but upgrade it to UBI9:

```sh
git -C ~/projects/cloudigrade checkout master && \
git -C ~/projects/cloudigrade pull && \
BASE_REF=$(git -C ~/projects/cloudigrade rev-parse --short HEAD)

UBI=9 BASE_REF="${BASE_REF}" ./scripts/ubi-perf-test.sh
```

## Cleanup

Running the script by default always reserves a new ephemeral namespace. You may want to clean these up between runs.

```sh
bonfire namespace list --mine
bonfire namespace release -f ephemeral-potato  # etc
```
