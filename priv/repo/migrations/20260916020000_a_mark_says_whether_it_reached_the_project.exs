defmodule CodeMySpec.Repo.Migrations.AMarkSaysWhetherItReachedTheProject do
  use Ecto.Migration

  # `graph_invalidations` had two states and needs three.
  #
  # A row with both entity columns null meant "this writer could not say what it
  # moved", and the consumer reads that as "any of it" — every entity plus the
  # project requirements. That is correct and it is also what every writer that
  # names its entities was implicitly avoiding, so there was no way for a writer
  # to say the useful third thing: *I know exactly which entities I moved, and I
  # also moved something the project requirements read.*
  #
  # Without that, `ShadowProjector` recomputed project nodes on every drain —
  # 60-95ms on this project, against 7ms for the story the mark actually named.
  # Project requirements are rebuilt unconditionally in the fingerprint pass for
  # the same reason, and there the cost has nowhere to go; here it does.
  #
  # The three states, and the polarity is deliberate:
  #
  #   * `"entity"` — the row names a component or story, and the writer is
  #     asserting it moved nothing the project requirements read.
  #   * `"project"` — the project requirements moved. Recorded *alongside* a
  #     writer's entity marks, not instead of them.
  #   * `"unknown"` — the writer could not say. Everything recomputes.
  #
  # `"unknown"` is the default for a reason. A writer that has not been taught
  # to narrow itself, and a writer added later by someone who never reads this,
  # both land there and both stay correct. Only a writer that has explicitly
  # claimed a blast radius gets the cheap path, which puts the knowledge at the
  # call site that has it and makes the conservative case the one you get for
  # free.
  def up do
    alter table(:graph_invalidations) do
      add :entity_scope, :string
    end

    # Existing rows predate the distinction, so they take the safe reading.
    execute("UPDATE graph_invalidations SET entity_scope = 'unknown' WHERE entity_scope IS NULL")
  end

  def down do
    alter table(:graph_invalidations) do
      remove :entity_scope
    end
  end
end
