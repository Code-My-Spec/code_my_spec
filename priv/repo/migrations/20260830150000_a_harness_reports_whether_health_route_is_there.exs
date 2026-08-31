defmodule CodeMySpec.Repo.Migrations.AHarnessReportsWhetherHealthRouteIsThere do
  @moduledoc """
  Same gap `module_name` had, on a check that has no Files-table fallback.

  `DeployBoilerplate.health_route_unpiped/2` is a content check — it reads
  `router.ex`/`endpoint.ex` looking for an unpiped `/health` route — and the
  Files sync table records existence, never content. For a project reached
  only through a live harness connection, `scope.environment` server-side
  resolves through `Resources.project_scope/2`'s fallback to a path on the
  checkout's own machine, not this one, so `Environments.read_file/2` there
  answers `nil`/an error regardless of what the file actually contains.

  Nullable, and stays that way: a project onboarded before this exists, or
  whose harness has not synced since, has not said yet. That is a real,
  honest state — "unreported" — not the same as "checked and missing".
  """

  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :health_route_status, :string
    end
  end
end
