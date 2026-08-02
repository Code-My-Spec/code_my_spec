# postgres-flex + pgvector

The image `code-my-spec-prod-db` runs. Upstream `flyio/postgres-flex` ships
PostGIS and no pgvector — its `pg17/Dockerfile` installs no
`postgresql-17-pgvector`, and that is still true on master, so there is no
version to upgrade to that would have provided it. Without the extension,
`CREATE EXTENSION vector` in `20260729010000_create_doc_embeddings` fails with
`feature_not_supported`, `/app/bin/migrate` exits 1, and every deploy aborts
before the machines swap. That is what happened between 2026-07-30 and
2026-08-01.

`pgvector.patch` is the delta against upstream. Two hunks:

  * `postgresql-${PG_MAJOR_VERSION}-pgvector`, from the PGDG apt repo the
    Dockerfile already configures — the same source Postgres itself comes
    from. This is the point of the patch.
  * `REPMGR_VERSION`, bumped from `5.5.0+debpgdg-1.pgdg24.04+1` to `-3`.
    Not optional and not cosmetic: PGDG no longer carries `-1`, so v0.0.66's
    Dockerfile does not build at all today. Same repmgr 5.5.0, newer Debian
    packaging revision. Expect this pin to rot again.

## Rebuilding

Built from the tag the production machine already ran, so pgvector is the only
intended change. Bump the tag deliberately, not incidentally — the machine's
current image is the fallback if a new one misbehaves.

    git clone --depth 1 --branch v0.0.66 https://github.com/fly-apps/postgres-flex.git
    cd postgres-flex
    git apply /path/to/pgvector.patch
    fly deploy --build-only --push --remote-only \
      -a code-my-spec-prod-db \
      --dockerfile pg17/Dockerfile \
      --image-label pgvector-v0.0.66 .

Note `postgresql-${PG_MAJOR_VERSION}` is unpinned upstream, so a rebuild picks
up the current 17.x from PGDG rather than 17.2. Minor-version binaries read a
17.x data directory without `pg_upgrade`, which is why this is safe; a *major*
version bump is not, and is not what this patch is for.

Verify the built image before putting a database on it — apt fails loudly on a
missing package, but the control file landing in the right directory is the
thing that actually matters:

    fly apps create <scratch> -o personal
    fly machine run registry.fly.io/code-my-spec-prod-db:pgvector-v0.0.66 \
      -a <scratch> --region yyz --restart no -- \
      sh -c 'ls /usr/share/postgresql/17/extension/ | grep -i vector'
    fly logs -a <scratch> --no-tail
    fly apps destroy <scratch> -y

Expect `vector.control` and `vector.so`.

## Deploying it

Take a snapshot first. An image swap does not touch `/data`, where PGDATA
lives, but a production database earns the restore point anyway.

    TOKEN=$(fly auth token)
    curl -s -X POST -H "Authorization: Bearer $TOKEN" \
      https://api.machines.dev/v1/apps/code-my-spec-prod-db/volumes/<vol-id>/snapshots

flyctl v0.4.76's `fly volumes snapshots` subcommands fail against the current
API (`Field 'node' doesn't exist on type 'Queries'`) — hence the REST call.

    fly machine update <machine-id> \
      --image registry.fly.io/code-my-spec-prod-db:pgvector-v0.0.66 \
      -a code-my-spec-prod-db -y

Single-node cluster, so Postgres restarts and the app reconnects — a brief
blip, not a migration. Roll back by pointing `--image` at the previous ref;
the volume is untouched either way.
