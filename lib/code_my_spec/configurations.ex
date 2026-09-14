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
    deps: [CodeMySpec, CodeMySpec.Repo, CodeMySpec.Requirements, CodeMySpec.Users],
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
      nil ->
        %ProjectConfiguration{}
        |> ProjectConfiguration.changeset(%{project_id: project_id})
        |> Repo.insert!()

      config ->
        config
    end
  end

  @doc """
  Update the active project's configuration.
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

    # `GraphFingerprint` hashes the configuration, and it decides real gates —
    # `require_specs?` alone adds or removes a requirement on every component
    # in the project. Turning it on is work appearing for a role that has
    # nothing to read that would tell it so.
    case result do
      {:ok, _config} -> GraphInputs.announce(scope, "Configurations")
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
  Whether the active project requires specs as a generated artifact.
  Drives `Documents.create_dynamic_document`'s strict-section gate:
  off means partial specs are allowed.

  Falls back to `true` when no scope/project is available so non-
  scoped callers stay in strict mode by default.
  """
  @spec require_specs?(Scope.t() | nil) :: boolean()
  def require_specs?(%Scope{active_project_id: project_id} = scope)
      when not is_nil(project_id) do
    get_or_create(scope).require_specs
  end

  def require_specs?(_), do: true

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
