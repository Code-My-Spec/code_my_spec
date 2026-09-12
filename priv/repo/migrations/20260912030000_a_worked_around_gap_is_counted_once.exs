defmodule CodeMySpec.Repo.Migrations.AWorkedAroundGapIsCountedOnce do
  @moduledoc """
  Capabilities a role should have had, and how often the main agent covered for
  their absence.

  Story 1058. The failure it closes is the comfortable one: an agent asks, the
  main agent answers, the work carries on — every time, forever. Nothing is
  broken and nothing is written down, and the role acquires a permanent
  dependency on somebody else looking things up for it.

  A gap that blocks gets fixed. One that is smoothly worked around is invisible
  to everybody except the thing doing the smoothing, and that thing does not get
  tired.

  `occurrences` is why this is a table rather than a flag on an issue. Criterion
  3330 wants the repeats counted rather than dropped: "do not file again" alone
  throws away the evidence that decides whether this gap is worth closing before
  the next thing, and leaves triage with one data point and no idea it is the
  tip of anything.

  Unique on `{project_id, role, capability}`, which is what makes one gap one
  row however often it bites — the same reasoning as story 1056's restart
  suppression, applied to filing rather than to acting.
  """

  use Ecto.Migration

  def change do
    create table(:capability_gaps, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :role, :string, null: false
      add :capability, :text, null: false
      add :occurrences, :integer, null: false
      add :issue_id, references(:issues, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:capability_gaps, [:project_id, :role, :capability])
  end
end
