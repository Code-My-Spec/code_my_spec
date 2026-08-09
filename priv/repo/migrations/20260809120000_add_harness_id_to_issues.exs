defmodule CodeMySpec.Repo.Migrations.AddHarnessIdToIssues do
  use Ecto.Migration

  @moduledoc """
  Which working copy an issue was raised from.

  Files, problems and analysis runs all record it; issues did not, so the one
  question that gets asked about every report — "is this my checkout or
  another's?" — could only be answered from prose the author happened to type
  into the body, or not at all.

  It was asked in earnest today, about two spex failures blocking a stop, and
  took a database query over `problems` to settle. The marker issue raised to
  verify framework intake (9c8ade27) states the acceptance criterion outright:
  scope, severity and working copy attached. Two of three were.

  Nullable and undefaulted, matching `analysis_runs`: issues raised before this
  cannot be attributed to a checkout, and inventing one would be worse than
  admitting it. Framework issues raised by a human through the web UI have no
  working copy at all, and that is a legitimate nil rather than a gap.
  """

  def change do
    alter table(:issues) do
      add :harness_id, references(:harnesses, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:issues, [:project_id, :harness_id])
  end
end
