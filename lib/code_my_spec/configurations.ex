defmodule CodeMySpec.Configurations do
  @moduledoc """
  Public API for local project configuration.

  One ProjectConfiguration per project. Auto-creates with defaults on first
  access — the engineer never has to visit the config screen to get the
  standard behavior.

  Local-only: not synced to the server.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Repo, CodeMySpec.Requirements.GraphInputs, CodeMySpec.Users.Scope],
    exports: :all

  alias CodeMySpec.Configurations.ProjectConfiguration
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Users.Scope

  @doc """
  The active project's configuration, or nil.

  The read that does not write. `get_or_create/1` is right for a caller about
  to edit the configuration; it is wrong for anything merely displaying one,
  and using it there quietly creates a row for every project the page touches.
  """
  @spec get(Scope.t()) :: ProjectConfiguration.t() | nil
  def get(%Scope{active_project_id: project_id}) when not is_nil(project_id) do
    Repo.get_by(ProjectConfiguration, project_id: project_id)
  end

  def get(_scope), do: nil

  @doc """
  Get the configuration for the active project, creating with defaults if missing.
  """
  @spec get_or_create(Scope.t()) :: ProjectConfiguration.t()
  def get_or_create(%Scope{active_project_id: project_id}) when not is_nil(project_id) do
    case Repo.get_by(ProjectConfiguration, project_id: project_id) do
      nil -> create_or_refetch(project_id)
      config -> config
    end
  end

  # 09fd73a4: a read-then-insert race between the get_by above and this insert
  # -- two callers for the same project, neither seeing the other's row yet --
  # used to raise Ecto.InvalidChangesetError (unique_constraint(:project_id)
  # turns the DB's own conflict into a changeset error, but get_or_create
  # still called insert!, which raises on it either way). Reproduced directly
  # under concurrent load: IncrementalGraph.drain/1's rescue clause swallowed
  # that raise and left the project's graph however stale it already was,
  # which is what let a satisfied requirement (ready_for_qa) keep being
  # offered after its own recompute kept failing this way.
  #
  # Losing the race is not an error: the configuration this call wanted now
  # exists, made by whichever caller won it, so fetching it is correct rather
  # than raising over a row this call itself asked to have exist. Any other
  # changeset failure still raises exactly as insert! would have.
  defp create_or_refetch(project_id) do
    %ProjectConfiguration{}
    |> ProjectConfiguration.changeset(%{project_id: project_id})
    |> Repo.insert()
    |> case do
      {:ok, config} ->
        config

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :project_id) do
          Repo.get_by!(ProjectConfiguration, project_id: project_id)
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  @doc """
  Update the active project's configuration.

  Raw write. A change that can move `fix_issues_min_severity` goes through
  `CodeMySpec.TaskOwner.update_configuration/2`, which also frees tasks
  waiting on issues the new threshold leaves below it.
  """
  @spec update(Scope.t(), map()) ::
          {:ok, ProjectConfiguration.t()} | {:error, Ecto.Changeset.t()}
  def update(%Scope{active_project_id: project_id} = scope, attrs)
      when not is_nil(project_id) do
    result =
      scope
      |> get_or_create()
      |> ProjectConfiguration.changeset(attrs)
      |> Repo.update()

    # Configuration can change project gates and analyzer policy.
    case result do
      {:ok, _config} -> GraphInputs.announce(scope, "Configurations", [], :project_wide)
      {:error, _changeset} -> :ok
    end

    result
  end

  @doc """
  Build a changeset for form rendering.
  """
  @spec change(ProjectConfiguration.t(), map()) :: Ecto.Changeset.t()
  def change(%ProjectConfiguration{} = configuration, attrs \\ %{}) do
    ProjectConfiguration.changeset(configuration, attrs)
  end

  @doc """
  Minimum issue severity the FixIssues loop gates on. Accepted issues
  at or above this severity block `evaluate_task` for `issues_resolved`;
  anything below is tracked but ignored by the loop.

  Defaults to `:medium` when no scope/project is in play.
  """
  @spec fix_issues_min_severity(Scope.t() | nil) ::
          :critical | :high | :medium | :low | :info
  def fix_issues_min_severity(%Scope{active_project_id: project_id} = scope)
      when not is_nil(project_id) do
    get_or_create(scope).fix_issues_min_severity || :medium
  end

  def fix_issues_min_severity(_), do: :medium

  @default_cadence_seconds 20 * 60

  @doc """
  How often this project's main agent is woken to look in on its agents.

  Twenty minutes when no scope or project is in play, matching the schema's
  default — the two are stated in both places because a reader of either should
  not have to find the other, and a `validate_number(greater_than: 0)` keeps
  them from drifting into disagreement about what is even allowed.
  """
  @spec main_agent_cadence_seconds(Scope.t() | nil) :: pos_integer()
  def main_agent_cadence_seconds(%Scope{active_project_id: project_id} = scope)
      when not is_nil(project_id) do
    get_or_create(scope).main_agent_cadence_seconds || @default_cadence_seconds
  end

  def main_agent_cadence_seconds(_), do: @default_cadence_seconds
end
