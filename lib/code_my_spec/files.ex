defmodule CodeMySpec.Files do
  @moduledoc """
  Context for managing tracked project files.
  """

  import Ecto.Query

  alias CodeMySpec.Files.File
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @doc "List all files for the project."
  @spec list_files(Scope.t()) :: [File.t()]
  def list_files(%Scope{active_project_id: project_id}) do
    File
    |> where([f], f.project_id == ^project_id)
    |> Repo.all()
  end

  @doc "List files for a specific component."
  @spec list_component_files(Scope.t(), Ecto.UUID.t()) :: [File.t()]
  def list_component_files(%Scope{active_project_id: project_id}, component_id) do
    File
    |> where([f], f.project_id == ^project_id and f.component_id == ^component_id)
    |> Repo.all()
  end

  @doc "List files for a specific story."
  @spec list_story_files(Scope.t(), integer()) :: [File.t()]
  def list_story_files(%Scope{active_project_id: project_id}, story_id) do
    File
    |> where([f], f.project_id == ^project_id and f.story_id == ^story_id)
    |> Repo.all()
  end

  @doc "Get a file by path within the project."
  @spec get_by_path(Scope.t(), String.t()) :: File.t() | nil
  def get_by_path(%Scope{active_project_id: project_id}, path) do
    File
    |> where([f], f.project_id == ^project_id and f.path == ^path)
    |> Repo.one()
  end

  @doc "Get multiple files by paths."
  @spec get_by_paths(Scope.t(), [String.t()]) :: [File.t()]
  def get_by_paths(%Scope{active_project_id: project_id}, paths) when is_list(paths) do
    File
    |> where([f], f.project_id == ^project_id and f.path in ^paths)
    |> Repo.all()
  end

  @doc """
  Bulk upsert files. Inserts new files or updates mtime/size/role/owner for existing ones.

  Returns `{inserted_count, updated_files}`.
  """
  @spec upsert_files(Scope.t(), [map()]) :: {integer(), [File.t()] | nil}
  def upsert_files(%Scope{active_project_id: project_id}, file_attrs_list)
      when is_list(file_attrs_list) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entries =
      Enum.map(file_attrs_list, fn attrs ->
        attrs
        |> Map.put(:project_id, project_id)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    Repo.insert_all(File, entries,
      on_conflict:
        {:replace, [:role, :mtime, :size, :valid, :validation_errors, :component_id, :story_id, :updated_at]},
      conflict_target: [:project_id, :path],
      returning: true
    )
  end

  @doc """
  Delete files that exist in DB but not in the provided path list.

  Used during sync to clean up files that were removed from the filesystem.
  """
  @spec delete_removed(Scope.t(), [String.t()]) :: {integer(), nil}
  def delete_removed(%Scope{active_project_id: project_id}, current_paths)
      when is_list(current_paths) do
    File
    |> where([f], f.project_id == ^project_id and f.path not in ^current_paths)
    |> Repo.delete_all()
  end

  @doc """
  Find files that changed — mtime in DB differs from provided mtime map.

  Takes a map of `%{path => mtime}` and returns File records where the stored
  mtime is older than the filesystem mtime (or the file is new).
  """
  @spec changed_files(Scope.t(), %{String.t() => DateTime.t()}) :: [File.t()]
  def changed_files(%Scope{active_project_id: project_id}, path_mtime_map)
      when is_map(path_mtime_map) do
    paths = Map.keys(path_mtime_map)

    existing =
      File
      |> where([f], f.project_id == ^project_id and f.path in ^paths)
      |> Repo.all()
      |> Map.new(&{&1.path, &1})

    Enum.filter(paths, fn path ->
      case Map.get(existing, path) do
        nil -> true
        file -> DateTime.compare(Map.fetch!(path_mtime_map, path), file.mtime) == :gt
      end
    end)
    |> Enum.map(fn path -> Map.get(existing, path) end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "List files that need validation (valid is nil)."
  @spec files_needing_validation(Scope.t()) :: [File.t()]
  def files_needing_validation(%Scope{active_project_id: project_id}) do
    File
    |> where([f], f.project_id == ^project_id and is_nil(f.valid))
    |> Repo.all()
  end

  @doc "Mark a file as validated (pass or fail)."
  @spec mark_validated(File.t(), boolean(), map() | nil) ::
          {:ok, File.t()} | {:error, Ecto.Changeset.t()}
  def mark_validated(%File{} = file, valid, errors \\ nil) do
    file
    |> File.changeset(%{valid: valid, validation_errors: errors})
    |> Repo.update()
  end

  @doc """
  Check if a component has a file with the given role.
  """
  @spec has_file?(Scope.t(), Ecto.UUID.t(), atom()) :: boolean()
  def has_file?(%Scope{active_project_id: project_id}, component_id, role) do
    File
    |> where([f], f.project_id == ^project_id and f.component_id == ^component_id and f.role == ^role)
    |> Repo.exists?()
  end

  @doc """
  Check if a component has a valid file with the given role.
  """
  @spec has_valid_file?(Scope.t(), Ecto.UUID.t(), atom()) :: boolean()
  def has_valid_file?(%Scope{active_project_id: project_id}, component_id, role) do
    File
    |> where([f],
      f.project_id == ^project_id and
        f.component_id == ^component_id and
        f.role == ^role and
        f.valid == true
    )
    |> Repo.exists?()
  end
end
