defmodule CmsHarness.ProjectIdentity do
  @moduledoc """
  Which project a directory is.

  The server used to answer this by looking a filesystem path up in its own
  database, which is precisely the question a server with no disk cannot
  answer. So the harness answers it, locally, and the server only ever receives
  an id.

  Resolution order, matching `Projects.resolve_local_project/1` on the server:

    1. `CMS_PROJECT_ID` — what a sprite sets, and it wins
    2. `project_id` in the project's `.code_my_spec/config.yml`
    3. refuse

  There is no fourth step. A directory that cannot say which project it is gets
  an error naming the file it should have said it in, because guessing here
  means syncing one checkout's files over another project's rows.
  """

  @config_path ".code_my_spec/config.yml"

  @type t :: %{id: String.t(), root: String.t()}

  @doc """
  Resolve the project id for a working directory.

  `root` is normalised to an absolute path so two spellings of the same
  checkout cannot start two subtrees against one project.
  """
  @spec resolve(String.t()) ::
          {:ok, t()} | {:error, :no_project_id | :unreadable_config | {:invalid_config, term()}}
  def resolve(root) when is_binary(root) do
    root = Path.expand(root)

    case System.get_env("CMS_PROJECT_ID") do
      id when is_binary(id) and id != "" -> {:ok, %{id: id, root: root}}
      _ -> from_config(root)
    end
  end

  @doc "The path the id is expected to live in, for error messages."
  @spec config_path(String.t()) :: String.t()
  def config_path(root), do: Path.join(Path.expand(root), @config_path)

  defp from_config(root) do
    path = config_path(root)

    with {:ok, contents} <- read(path),
         {:ok, parsed} <- parse(contents),
         id when is_binary(id) and id != "" <- to_string_id(parsed["project_id"]) do
      {:ok, %{id: id, root: root}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :no_project_id}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:error, :no_project_id}
      {:error, _} -> {:error, :unreadable_config}
    end
  end

  defp parse(contents) do
    case YamlElixir.read_from_string(contents) do
      {:ok, %{} = parsed} -> {:ok, parsed}
      {:ok, _} -> {:error, {:invalid_config, :not_a_mapping}}
      {:error, reason} -> {:error, {:invalid_config, reason}}
    end
  end

  # YAML gives an integer for `project_id: 712`; the topic is a string either
  # way. Normalising here means the channel client never has to care.
  defp to_string_id(id) when is_integer(id), do: Integer.to_string(id)
  defp to_string_id(id) when is_binary(id), do: String.trim(id)
  defp to_string_id(_), do: nil
end
