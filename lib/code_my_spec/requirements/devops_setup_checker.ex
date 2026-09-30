defmodule CodeMySpec.Requirements.DevopsSetupChecker do
  @moduledoc """
  Whether an environment's devops setup is complete enough to take a deploy.

  `deploy` stays unsatisfied until a health-verified deploy exists, and while
  setup is incomplete that work cannot be done. So the node carries the missing
  steps and is not offered (a86c85dd): the main agent was claiming every deploy,
  failing on the missing setup, and tapping out.

  The answer is `Resources.setup_missing/3`, the checklist `devops_status`
  reports, not a second reading of the step rows.
  """

  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Resources
  alias CodeMySpec.Users.Scope

  @waiting_on "devops_setup"

  @doc """
  The steps `environment` is still missing, as `env/key` (or `key` for a
  project-wide step). `:not_started` when the environment has no row yet, so
  every step is missing. Empty when setup is complete or devops is off.

  Never writes: the graph calls this on every load.
  """
  @spec missing(Scope.t(), String.t()) :: [String.t()] | :not_started
  def missing(%Scope{} = scope, environment) do
    with %Project{} = project <- project(scope),
         {:ok, steps} <- Resources.setup_missing(scope, project, environment) do
      steps |> Enum.map(&label/1) |> Enum.uniq()
    else
      {:error, :not_started} -> :not_started
      _ -> []
    end
  end

  @doc """
  The details of a `deploy` node with no health-verified deploy.

  With setup missing, the reason names the steps and `waiting_on` keeps the node
  from being offered — see `Requirement.waiting?/1`.
  """
  @spec undeployed(String.t(), [String.t()] | :not_started) :: map()
  def undeployed(environment, []),
    do: %{status: "not deployed to #{environment}, or deployed without a passing health check"}

  def undeployed(environment, :not_started),
    do: %{reason: "devops setup not started for #{environment}", waiting_on: @waiting_on}

  def undeployed(environment, missing),
    do: %{
      reason: "devops setup incomplete for #{environment}: #{Enum.join(missing, ", ")}",
      waiting_on: @waiting_on,
      missing_setup: missing
    }

  defp label(%{environment: env, key: key}) when is_binary(env), do: "#{env}/#{key}"
  defp label(%{key: key}), do: to_string(key)

  defp project(%Scope{active_project: %Project{id: id} = project, active_project_id: id}),
    do: project

  defp project(%Scope{active_project_id: id} = scope) when is_binary(id) do
    case Projects.get_project(scope, id) do
      {:ok, project} -> project
      _ -> nil
    end
  end

  defp project(_scope), do: nil
end
