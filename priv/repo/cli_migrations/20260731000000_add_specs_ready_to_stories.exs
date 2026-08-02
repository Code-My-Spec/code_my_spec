defmodule CodeMySpec.Repo.Migrations.AddSpecsReadyToStories do
  use Ecto.Migration

  def change do
    alter table(:stories) do
      # The latch behind the `bdd_specs_passing` requirement. Set when a
      # fresh spex run shows every one of the story's BDD specs green;
      # cleared when the chain restarts or the user clears it by hand.
      #
      # No default here on purpose — defaults live on the schema.
      add :specs_ready, :boolean
    end

    # Grandfathering: a story that already has a passing QA attempt shipped
    # under the old graph, where `bdd_specs_passing` did not exist. Leaving
    # those at NULL would reopen a satisfied node on every completed story
    # and put the whole back catalogue back in the queue. Stories still in
    # flight start unlatched, which is correct — they have not gone green.
    execute(
      """
      UPDATE stories SET specs_ready = true
      WHERE id IN (SELECT story_id FROM qa_attempts WHERE status = 'pass')
      """,
      "SELECT 1"
    )
  end
end
