defmodule CodeMySpec.McpServers.Components.Tools.FreezeComponents do
  @moduledoc """
  The one-time freeze of a project's components into records (3aeb66cf, step
  3); see `CodeMySpec.Files.ComponentFreeze`.

  A dry run unless `dry_run: false` is passed, because it rewrites live
  component data: read the report first. Covers every project in the caller's
  account unless `project_id` names one. A project already frozen is skipped.
  """

  use Anubis.Server.Component, type: :tool

  import Ecto.Query, only: [from: 2]

  alias Anubis.Server.Response
  alias CodeMySpec.Files.ComponentFreeze
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo

  schema do
    field :project_id, :string,
      description: "One project; omitted means every project in the account"

    field :dry_run, :boolean, description: "Report only (the default). false writes."
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_scope(frame) do
      {:ok, scope} ->
        write? = Map.get(params, :dry_run) == false

        text =
          scope
          |> project_ids(Map.get(params, :project_id))
          |> Enum.map_join("\n\n", &render(run(&1, write?), write?))

        {:reply, Response.tool() |> Response.text(text), frame}

      {:error, reason} ->
        {:reply, Response.tool() |> Response.error(inspect(reason)), frame}
    end
  end

  defp project_ids(scope, nil),
    do:
      Repo.all(from(p in Project, where: p.account_id == ^scope.active_account_id, select: p.id))

  defp project_ids(scope, id),
    do:
      Repo.all(
        from(p in Project,
          where: p.account_id == ^scope.active_account_id and p.id == ^id,
          select: p.id
        )
      )

  defp run(project_id, false), do: ComponentFreeze.plan(project_id)

  defp run(project_id, true) do
    case ComponentFreeze.freeze(project_id) do
      {:ok, :already_frozen} -> Map.put(ComponentFreeze.plan(project_id), :skipped, true)
      {:ok, report} -> report
    end
  end

  defp render(%{skipped: true} = r, _write?),
    do: "#{r.project} (#{r.project_id}): already frozen at #{r.frozen_at}; left alone."

  defp render(%{frozen_at: %DateTime{}} = r, false),
    do:
      "#{r.project} (#{r.project_id}): already frozen at #{r.frozen_at}; a freeze would skip it."

  defp render(r, write?) do
    verb = if write?, do: "Froze", else: "Would freeze"

    """
    #{verb} #{r.project} (#{r.project_id}):
    - authored: #{length(r.to_author)} (#{Enum.join(r.to_author, ", ")})
    - discovered: #{r.to_discover}
    - already authored: #{r.already_authored}
    - edges to mark authored: #{r.edges_to_author}
    - named only by a stale checkout's spec, so discovered: #{list(r.stale_spec_only)}
    - specs in a live checkout naming no component: #{list(r.specs_without_component)}\
    """
  end

  defp list([]), do: "none"
  defp list(names), do: "#{length(names)} (#{Enum.join(names, ", ")})"
end
