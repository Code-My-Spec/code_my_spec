defmodule CodeMySpec.McpServers.Devops.Tools.RunProvisioningStep do
  @moduledoc """
  Run one named provisioning step directly, skipping the sequence's own
  halt-on-first-failure ordering.

  `run_devops_setup` walks `Sequence.for_options/1` in order and halts at the
  first step that is not done — the ordering *is* the dependency model, so a
  step later in the sequence normally has no business running before an
  earlier one does. That stops being true the moment an earlier step is
  blocked for a reason that has nothing to do with whether later steps can
  actually succeed: `:repository` and `:secrets` need to run real commands
  against a local checkout, which nothing reached through the light harness
  (`/mcp/harness`) can currently do — so they read "missing" indefinitely
  regardless of whether the account's real infrastructure (`:server`,
  `:domain`, `:dns`, and anything else that is purely a provider API call) is
  actually fine. Waiting on the sequence to reach them means never verifying
  the parts that already work.

  This is the same `run_step/3` `run_devops_setup` and `adopt_repository`
  both already use underneath — verified against the provider first, same
  `RunLock` respected, same honest outcome reported back. It does not bypass
  a step's own verification; it only bypasses *ordering*. Running `:deploy`
  before `:server` genuinely exists is still that step's problem to refuse,
  not this tool's to prevent.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Projects
  alias CodeMySpec.Provisioning
  alias CodeMySpec.Provisioning.RunLock
  alias CodeMySpec.Provisioning.Step
  alias CodeMySpec.Resources

  schema do
    field :project_id, :string, required: true, doc: "Run the step for this project."

    field :step, :string,
      required: true,
      doc: "One of: #{Step.keys() |> Enum.map_join(", ", &to_string/1)}."
  end

  @impl true
  def execute(%{project_id: project_id, step: step} = params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, project} <- find_project(scope, project_id),
         {:ok, key} <- find_step(step) do
      scope = Resources.project_scope(scope, project)

      RunLock.with_lock(project.id, fn -> Provisioning.run_step(scope, key) end)
      |> reply(step, project, frame)
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

  defp find_step(step) do
    case Enum.find(Step.keys(), &(to_string(&1) == step)) do
      nil -> {:error, "unknown step #{inspect(step)} — must be one of #{Enum.map_join(Step.keys(), ", ", &to_string/1)}"}
      key -> {:ok, key}
    end
  end

  defp reply({:error, {:already_running, started_at}}, _step, _project, frame) do
    since = started_at && " (started #{started_at})"
    {:reply, error("a setup run is already in progress for this project#{since} — call devops_status rather than retrying"), frame}
  end

  defp reply({:ok, %{state: state}}, step, project, frame) do
    {:reply, ok("#{step} for #{project.name} is now #{state}."), frame}
  end

  # Paused is a real, expected outcome — waiting on something only a person
  # can do — not a failure of this call.
  defp reply({:halt, %{state: :paused}, reason}, step, project, frame) do
    {:reply, ok("#{step} for #{project.name} is paused: #{reason}"), frame}
  end

  defp reply({:halt, %{state: state}, reason}, step, project, frame) do
    {:reply, error("#{step} for #{project.name} is now #{state}: #{reason}"), frame}
  end

  defp ok(text), do: Response.tool() |> Response.text(text)

  defp error(reason),
    do: Response.tool() |> Response.error("Could not run the step: #{inspect(reason)}")
end
