defmodule CodeMySpec.Repo.Migrations.DocPackagesTrackRetryAttempts do
  @moduledoc """
  577de9bb step 3 follow-up: a package whose fetch/embed hangs or errors
  with no deterministic cause (a closed connection, a timeout, hex.pm's
  own 5xx) is deferred rather than marked `failed` — but deferred-forever
  with no bookkeeping means a package that hangs on *every* attempt
  retries, and burns a concurrency slot, forever. `attempts` bounds that:
  after enough tries the package is marked `failed` instead, same as any
  other terminal outcome.

  No DB default: every row this reconciler writes to `status: "pending"`
  sets `attempts` explicitly, and `pending/0`'s own query only reads it
  for rows already in that status — a terminal row (`embedded`, `no_docs`,
  `failed`) never needs it, so leaving it null there is the honest answer
  rather than a number nothing produced.
  """

  use Ecto.Migration

  def change do
    alter table(:doc_packages) do
      add :attempts, :integer
    end
  end
end
