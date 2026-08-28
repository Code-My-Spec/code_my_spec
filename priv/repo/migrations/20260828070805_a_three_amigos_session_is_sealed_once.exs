defmodule CodeMySpec.Repo.Migrations.AThreeAmigosSessionIsSealedOnce do
  use Ecto.Migration

  @moduledoc """
  The seal behind `three_amigos_complete`, in the same shape as `specs_ready`
  behind `bdd_specs_passing`: a latch the gate flips once, rather than a
  condition recomputed forever.

  Recomputing is what the requirement did before, and it meant a red card added
  to a shipped story quietly un-shipped it. A seal is a statement about a
  conversation that happened, and adding a question afterwards does not unhappen
  it — it is the next conversation.

  ## Backfilled, deliberately

  Every story that satisfies the rule as it stands today is sealed here.
  Tightening the red-card rule at the same time as introducing the latch would
  otherwise pull 50 released stories backwards at once, several of them with
  agents working in them — measured on this database before writing this.

  The stricter rule applies to what gets sealed from now on. That is what a
  latch is for: work that passed the bar it was held to stays passed.

  The backfill is deliberately written against the *old* lenient signal
  (`scenarios > open questions`) rather than the new one, because the whole
  point is to grandfather what already qualified. It is a snapshot of a rule
  that no longer exists anywhere else in the codebase, so it is spelled out here
  rather than delegated to a module that will change under it.

  Including the old rule's "every rule has a scenario" clause, which the first
  draft of this migration left out. That draft sealed two stories carrying a
  rule with no scenarios — stories the gate had never passed. Grandfathering has
  to mean exactly what already qualified; a backfill looser than the rule it
  replaces grants completeness that was never earned, and a seal is permanent.
  """

  def up do
    alter table(:stories) do
      add :three_amigos_sealed, :boolean, null: false, default: false
    end

    # `kind IS NOT NULL` is what makes a criterion a Three Amigos scenario
    # (green card); untagged legacy criteria never counted toward the gate.
    execute("""
    UPDATE stories s
    SET three_amigos_sealed = true
    WHERE EXISTS (SELECT 1 FROM persona_stories ps WHERE ps.story_id = s.id)
      AND EXISTS (SELECT 1 FROM bdd_rules r WHERE r.story_id = s.id)
      AND (
        SELECT COUNT(*) FROM criteria c
        WHERE c.story_id = s.id AND c.kind IS NOT NULL
      ) > (
        SELECT COUNT(*) FROM questions q
        WHERE q.story_id = s.id AND q.status = 'open'
      )
      AND NOT EXISTS (
        SELECT 1 FROM bdd_rules r
        WHERE r.story_id = s.id
          AND NOT EXISTS (
            SELECT 1 FROM criteria c
            WHERE c.rule_id = r.id AND c.kind IS NOT NULL
          )
      )
    """)
  end

  def down do
    alter table(:stories) do
      remove :three_amigos_sealed
    end
  end
end
