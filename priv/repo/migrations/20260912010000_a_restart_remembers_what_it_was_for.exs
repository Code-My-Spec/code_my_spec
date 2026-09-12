defmodule CodeMySpec.Repo.Migrations.ARestartRemembersWhatItWasFor do
  @moduledoc """
  Why each agent was restarted, so a restart can be judged afterwards.

  Story 1056. The main agent restarts on its own judgement and will do it far
  more often than a person would, so the thing a person supplied by getting
  bored has to be supplied by the record.

  A bare count cannot do it. Three restarts for three faults is a busy morning
  and three for one fault is a loop, and every later criterion on the story
  turns on telling those apart: 3292 refuses a remedy already tried, 3302 stops
  a remedy that *worked* counting against the next one, and 3308 raises a fault
  that outlived its remedy.

  `resolved_at` is what makes 3302 possible. Without it the count is of
  attempts rather than of unresolved attempts, and an agent looked after
  successfully three times gets refused on the fourth recurrence — punished for
  a history of remedies that all worked, with a sensible-sounding refusal nobody
  will dispute.

  `working_copies.tools_seen_at` is the other half: the moment a machine last
  answered that it can run something. It is the one general signal available
  for "the agent works again afterwards" — a turn completing would be better and
  does not exist for an agent that never got far enough to take one.
  """

  use Ecto.Migration

  def change do
    create table(:agent_restarts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :reason, :text, null: false
      add :resolved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # The question asked before every restart: what has already been tried for
    # this, and did it work.
    create index(:agent_restarts, [:agent_id, :resolved_at])

    alter table(:working_copies) do
      add :tools_seen_at, :utc_datetime_usec
    end
  end
end
