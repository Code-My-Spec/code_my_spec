defmodule CmsHarness.ProjectIdentity do
  @moduledoc """
  Which project a directory is.

  Answered locally by the harness, so the server, which has no disk, only ever
  receives an id.

  Resolution order:

    1. `project_id` in the working copy's own `.cms_harness.json`
    2. `project_id` in the working copy's own `.code_my_spec/config.yml`
    3. refuse

  The copy's record wins for the reason `server_url/1` gives: one repository is
  a different project on each server (ours is 708492f9 on dev and a3158f01 on
  codemyspec.com), and the tracked file can hold only one of them.

  There is no environment fallback. A directory that cannot say which project
  it is gets an error naming the file it should have said it in, because
  guessing here means syncing one checkout's files over another project's rows.

  See knowledge/harness/channel, "Project identity".
  """

  require Logger

  alias CmsHarness.HarnessConfig

  @config_path ".code_my_spec/config.yml"

  @type t :: %{
          id: String.t(),
          root: String.t(),
          working_copy_id: String.t() | nil,
          preview_url: String.t() | nil
        }

  @doc """
  Resolve the project id for a working directory.

  `root` is normalised to an absolute path so two spellings of the same
  checkout cannot start two subtrees against one project.
  """
  @spec resolve(String.t()) ::
          {:ok, t()}
          | {:error,
             :no_project_id | :unreadable_config | :restarting | {:invalid_config, term()}}
  def resolve(root) when is_binary(root) do
    root = Path.expand(root)

    with {:ok, source, project} <- resolve_project(root) do
      {:ok,
       project
       |> Map.put(:working_copy_id, working_copy_id(source, root))
       |> Map.put(:preview_url, preview_url(root))}
    end
  end

  # Always out of `.cms_harness.json`, whichever file named the project: it is
  # the only one onboarding writes it to. Reported to the server, not looked up
  # there, like `root`.
  defp preview_url(root) do
    case HarnessConfig.read_file(root) do
      {:ok, %{preview_url: url}} when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  defp resolve_project(root) do
    case from_harness_file(root) do
      {:ok, _source, _project} = found -> found
      {:error, :no_project_id} -> from_config_file(root)
    end
  end

  defp from_config_file(root) do
    with {:ok, project} <- from_config(root), do: note_disagreement(project, :config)
  end

  # The file onboarding writes; carries `project_id` as well as
  # `working_copy_id`.
  defp from_harness_file(root) do
    case HarnessConfig.read_file(root) do
      {:ok, %{project_id: id}} when is_binary(id) and id != "" ->
        note_disagreement(%{id: id, root: root}, :harness_file)

      _ ->
        {:error, :no_project_id}
    end
  end

  # No longer logs: it runs on every resolution, and a permanent disagreement
  # repeated forever trains readers to skip the log.
  defp note_disagreement(project, source), do: {:ok, source, project}

  # `nil` means "not issued yet", which is ordinary — the first join mints it.
  # An unreadable config also reads as `nil`, but `HarnessConfig.write/2`
  # refuses to overwrite one, so the stranding is contained to the session.
  #
  # The id always comes from the copy's own file, never the environment.
  # `resolve_project/1` never yields `:env`; that clause is unreachable.
  defp working_copy_id(:env, root) do
    case HarnessConfig.read(root) do
      {:ok, %{working_copy_id: id}} -> id
      _ -> nil
    end
  end

  defp working_copy_id(:config, root), do: from_harness_config(root)

  defp working_copy_id(:harness_file, root), do: from_harness_config(root)

  defp from_harness_config(root) do
    case HarnessConfig.read_file(root) do
      {:ok, %{working_copy_id: id}} -> id
      _ -> nil
    end
  end

  @doc "The path the id is expected to live in, for error messages."
  @spec config_path(String.t()) :: String.t()
  def config_path(root), do: Path.join(Path.expand(root), @config_path)

  @doc """
  The CodeMySpec this project belongs to, as the project's own checkout says.

  Read from `.code_my_spec/config.yml`, which is committed, so every clone
  inherits it and a checkout nobody has onboarded yet still knows where its id
  has to be minted. That is the one case `--server-url` exists for and the one
  `.cms_harness.json` cannot answer, because that file does not exist yet.

  Below the harness config on purpose. A project served by dev.codemyspec.com on
  one machine and codemyspec.com on another cannot have one right answer in a
  tracked file, and the copy is where that difference lives — so the committed
  value is the project's default and the copy's record is what actually happened.

  `nil` for a project that names none; the build's own default applies then.
  """
  @spec server_url(String.t()) :: String.t() | nil
  def server_url(root) do
    with {:ok, contents} <- read(config_path(root)),
         {:ok, parsed} <- parse(contents),
         url when is_binary(url) <- parsed["server_url"],
         trimmed when trimmed != "" <- String.trim(url) do
      trimmed
    else
      _ -> nil
    end
  end

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
      {:error, reason} -> parse_failure(reason, :init.get_status())
    end
  end

  @doc """
  What a failed parse means, given `:init.get_status/0`.

  Every parse calls `Application.start(:yamerl)`; while the VM is stopping,
  that call exits and YamlElixir reports it as `"malformed yaml"`. A failure
  while stopping is `{:error, :restarting}`, so nobody looks for a YAML error.
  """
  @spec parse_failure(term(), {atom(), term()}) ::
          {:error, :restarting | {:invalid_config, term()}}
  def parse_failure(_reason, {:stopping, _provided}), do: {:error, :restarting}
  def parse_failure(reason, _status), do: {:error, {:invalid_config, reason}}

  # YAML gives an integer for `project_id: 712`; the topic is a string either
  # way. Normalising here means the channel client never has to care.
  defp to_string_id(id) when is_integer(id), do: Integer.to_string(id)
  defp to_string_id(id) when is_binary(id), do: String.trim(id)
  defp to_string_id(_), do: nil
end
