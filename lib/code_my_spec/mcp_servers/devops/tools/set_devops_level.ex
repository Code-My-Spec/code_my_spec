defmodule CodeMySpec.McpServers.Devops.Tools.SetDevopsLevel do
  @moduledoc """
  Mark a project as devops-managed, so it shows up in `devops_status` at all.

  `devops_status`/`Resources.report/1` walk every project in the account
  whose `ProjectConfiguration.devops` is not `:off` — a project defaults to
  `:off` until something sets it, which nothing does automatically. A
  project provisioned by calling `run_provisioning_step` directly (rather
  than through `run_devops_setup`, which enables devops as a side effect of
  the web UI's own "Start setup" button) never has this flipped, so every
  real step it actually has can be true and it still reads as invisible —
  not missing, not present, just never asked about at all. Confirmed live:
  MarketMySpec's `devops_status` reported on a *different* project in the
  account for this exact reason, hours into onboarding it for real.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Configurations
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Projects
  alias CodeMySpec.Resources

  schema do
    field :project_id, :string, required: true, doc: "Mark this project as devops-managed."

    field :level, :string,
      required: true,
      doc: "One of: off, uat, prod."
  end

  @impl true
  def execute(%{project_id: project_id, level: level} = params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, project} <- find_project(scope, project_id),
         {:ok, level} <- find_level(level) do
      scope
      |> Resources.project_scope(project)
      |> Configurations.update(%{devops: level})
      |> reply(project, level, frame)
    else
      {:error, reason} -> {:reply, error(reason), frame}
    end
  end

  defp find_project(scope, project_id) do
    case Enum.find(Projects.list_projects(scope), &(&1.id == project_id)) do
      nil -> {:error, "no project #{project_id} on this account"}
      project -> {:ok, project}
    end
  end

  defp find_level(level) do
    case Enum.find([:off, :uat, :prod], &(to_string(&1) == level)) do
      nil -> {:error, "unknown level #{inspect(level)} — must be one of off, uat, prod"}
      level -> {:ok, level}
    end
  end

  defp reply({:ok, _config}, project, level, frame),
    do: {:reply, ok("#{project.name} is now devops-managed at #{level}."), frame}

  defp reply({:error, changeset}, _project, _level, frame),
    do: {:reply, error(changeset), frame}

  defp ok(text), do: Response.tool() |> Response.text(text)

  defp error(reason),
    do: Response.tool() |> Response.error("Could not set the devops level: #{inspect(reason)}")
end
