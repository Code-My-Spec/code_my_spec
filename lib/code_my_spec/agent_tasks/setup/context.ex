defmodule CodeMySpec.AgentTasks.Setup.Context do
  @moduledoc """
  Loads the persisted view of every setup-relevant file from the DB so that
  `Setup.*` step `check/1` calls can decide pass/fail with O(1) map lookups
  instead of touching the filesystem on every requirements graph render.

  Files are populated by `FileSync` (with role-specific validators that
  write per-concern keys into `validation_errors`). Step `check/1` decodes
  those keys.
  """

  import Ecto.Query

  alias CodeMySpec.Environments
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @setup_roles [
    :mix_exs,
    :credo_exs,
    :claude_md,
    :setup_config,
    :test_support,
    :agents_md,
    :rule
  ]

  @type t :: %__MODULE__{
          files_by_path: %{String.t() => FileRecord.t()},
          files_by_role: %{atom() => [FileRecord.t()]},
          environment: term() | nil,
          project_id: Ecto.UUID.t() | nil
        }

  defstruct files_by_path: %{}, files_by_role: %{}, environment: nil, project_id: nil

  @doc """
  Load setup-relevant File records for the project.

  Also stashes `scope.environment` so the one residual filesystem-bound step
  (ProjectStructure: directories aren't synced) can stat dirs without each
  step having to dig the env out of the scope itself.
  """
  @spec load(Scope.t()) :: t()
  def load(%Scope{active_project_id: nil} = scope) do
    %__MODULE__{environment: scope.environment, project_id: nil}
  end

  def load(%Scope{active_project_id: project_id} = scope) do
    files =
      FileRecord
      |> where([f], f.project_id == ^project_id and f.role in ^@setup_roles)
      |> Repo.all()

    %__MODULE__{
      files_by_path: Map.new(files, &{&1.path, &1}),
      files_by_role: Enum.group_by(files, & &1.role),
      environment: scope.environment,
      project_id: project_id
    }
  end

  @doc """
  Look up a File record by path. Returns nil if not synced.
  """
  @spec file(t(), String.t()) :: FileRecord.t() | nil
  def file(%__MODULE__{files_by_path: by_path}, path), do: Map.get(by_path, path)

  @doc """
  Return all File records with the given role.
  """
  @spec files_with_role(t(), atom()) :: [FileRecord.t()]
  def files_with_role(%__MODULE__{files_by_role: by_role}, role),
    do: Map.get(by_role, role, [])

  @doc """
  Read the per-concern error from a File's validation_errors.

  Returns `nil` if the concern passed, an error string if it failed, or
  the `missing_msg` if the file isn't in the DB at all (not synced yet).
  """
  @spec error(t(), String.t(), String.t() | atom(), String.t()) :: nil | String.t()
  def error(ctx, path, key, missing_msg) do
    case file(ctx, path) do
      nil -> missing_msg
      %FileRecord{validation_errors: nil} -> missing_msg
      %FileRecord{validation_errors: errors} -> Map.get(get_errors(errors), to_string(key))
    end
  end

  @doc """
  Read a `data` field from a File's validation_errors.
  """
  @spec data(t(), String.t(), String.t() | atom()) :: any() | nil
  def data(ctx, path, key) do
    case file(ctx, path) do
      nil -> nil
      %FileRecord{validation_errors: nil} -> nil
      %FileRecord{validation_errors: errors} -> Map.get(get_data(errors), to_string(key))
    end
  end

  @doc """
  Returns the app name extracted from mix.exs at sync time, or nil if mix.exs
  isn't synced or couldn't be parsed.
  """
  @spec app_name(t()) :: String.t() | nil
  def app_name(ctx), do: data(ctx, "mix.exs", :app_name)

  @doc """
  Stat a directory through the stashed environment. Used by ProjectStructure
  (directories aren't tracked as File records).
  """
  @spec dir_exists?(t(), String.t()) :: boolean()
  def dir_exists?(%__MODULE__{environment: nil}, _path), do: false
  def dir_exists?(%__MODULE__{environment: env}, path), do: Environments.file_exists?(env, path)

  defp get_errors(%{"errors" => e}) when is_map(e), do: e
  defp get_errors(_), do: %{}

  defp get_data(%{"data" => d}) when is_map(d), do: d
  defp get_data(_), do: %{}
end
