defmodule CodeMySpec.Repo.Migrations.AnEventCarriesWhatItDid do
  use Ecto.Migration

  # `graph_invalidations` recorded that an entity moved. That is an
  # *invalidation*, and an invalidation can only ever be answered by
  # re-deriving — which is the thing this whole exercise exists to stop doing.
  #
  # An issue arriving at medium severity **is** `issues_triaged = false`. There
  # is nothing to ask the database. But a mark saying "the project moved" throws
  # that away, and the consumer's only remaining verb is "recompute the
  # project", which on this codebase runs all fourteen project checkers — 238ms
  # and 22 checker invocations for one verdict that the event already knew.
  #
  # So a row now carries the event rather than its shadow: `kind` names what
  # happened in the domain, `payload` carries the fields a handler needs to
  # write the verdict directly.
  #
  # The entity columns stay, and rows without a `kind` keep their old meaning.
  # Not every requirement has a handler yet — 30 distinct names across 110
  # definitions — and one that does not still needs invalidating. The two models
  # coexist so the rollout is per requirement rather than all at once, and the
  # shadow diff names exactly which ones are still re-deriving.
  def up do
    alter table(:graph_invalidations) do
      add :kind, :string
      add :payload, :map
    end

    # Existing rows predate the distinction and are invalidations.
    execute("UPDATE graph_invalidations SET kind = 'invalidate' WHERE kind IS NULL")
  end

  def down do
    alter table(:graph_invalidations) do
      remove :kind
      remove :payload
    end
  end
end
