defmodule CodeMySpec.Repo.Migrations.QaJourneyWallabyIsGone do
  use Ecto.Migration

  # Issue a621b5dd: `qa_journey_wallaby` has no definition. Journeys are codified
  # as LiveView tests in the same session as `qa_journey_execute`, which now ends
  # the chain. Stored rows would be served until their entity recomputed;
  # deleting them cascades their `requirement_edges` / `shadow_requirement_edges`.
  #
  # Task history naming it (`agents.tasks`, `sessions.tasks`) is left alone:
  # every entry is terminal, and tasks are never cancelled here.
  #
  # Restore, from the backup taken before promote:
  #
  #     psql -d code_my_spec_dev -f ~/.codemyspec/backups/qa_journey_wallaby_rows_<date>.sql
  def up do
    for table <- ~w(requirements shadow_requirements) do
      execute("DELETE FROM #{table} WHERE name = 'qa_journey_wallaby'")
    end
  end

  # Derived rows: nothing to re-insert, and nothing recomputes them without
  # a definition.
  def down, do: :ok
end
