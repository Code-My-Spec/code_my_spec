# vector_migrations

The `doc_embeddings` migrations, held out of `priv/repo/migrations/` because
the production database cannot run them.

`code-my-spec-prod-db` runs `flyio/postgres-flex`, whose image ships PostGIS
and no pgvector — upstream's `pg17/Dockerfile` installs no
`postgresql-17-pgvector` package, so this is not a version to upgrade past.
`CREATE EXTENSION vector` fails with `feature_not_supported`, `/app/bin/migrate`
exits 1, and the deploy aborts before the machines swap. Every migration
authored after 2026-07-29 was stranded behind it.

This is temporary. The server is meant to *store and search* vectors while
clients generate them, so production does need pgvector — it needs a database
that has it. Fly Managed Postgres does (`vector` is enabled per-cluster from
the Extensions page). Once prod is moved, these three files move back into
`priv/repo/migrations/` and run in order like any other migration; their
versions predate what is applied by then, which `Ecto.Migrator` runs without
complaint.

Nothing in production reads this table in the meantime. `:embeddings_backend`
is unset outside the CLI and sprite runtimes, so `Embeddings.search/3` returns
`{:error, :embeddings_unavailable}` and the one server-side caller
(`McpServers.Knowledge.Tools.SemanticSearch`) already answers that with a
message rather than a crash.

## Running them

Nothing runs this directory automatically. `Release.migrate/0` and
`CodeMySpecLocalWeb.Migrator` both point elsewhere, and a sprite must never
migrate — its database is shared and central, migrated once by the server's
deploy rather than by each client that connects.

Against a database that has pgvector (a local Postgres for `:dev_sprite` work —
never a live dev server, which holds the compile lock):

    mix ecto.migrate --migrations-path priv/repo/vector_migrations

A `code_my_spec_dev` / `code_my_spec_sprite_dev` migrated before this split
already has the table and needs nothing. A freshly reset one does not, and
`Embeddings.PgVectorBackend` will fail against it until the command above is
run.

## Before moving them back

`doc_embeddings` has no column identifying which model produced a vector.
Cosine distance between two models' vectors is arithmetically valid and
semantically meaningless, and the shared rows (`project_id IS NULL`, unique on
`source, path, chunk_index`) are exactly where two CLI versions would overwrite
each other into one HNSW index — no error, just confident nonsense. That column
wants to exist before clients on differing versions write to a shared database.
