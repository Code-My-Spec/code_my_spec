defmodule CmsHarness.HarnessConfig do
  @moduledoc """
  What a working copy knows about itself: which harness it is, and where.

  One file per working copy, at its root, and only one:

      {"working_copy_id": "…", "harness_id": "…", "project_id": "…", "root": "/abs/path"}

  Plus `deploy_key` once the copy has one, and `preview_url` on the copy that is
  the project's main checkout — the address its preview answers on, written at
  onboarding and reported to the server on join, the same way `root` is.

  The file is gitignored and lives at the working-copy root, never under
  `.code_my_spec/` (a submodule). See knowledge/harness, "Working-copy identity".
  """

  require Logger

  @filename ".cms_harness.json"

  @type t :: %{
          working_copy_id: String.t(),
          project_id: String.t() | nil,
          deploy_key: String.t() | nil,
          preview_url: String.t() | nil,
          server_url: String.t() | nil,
          root: String.t()
        }

  @doc "Where the config lives for a working copy."
  @spec path(String.t()) :: String.t()
  def path(root), do: Path.join(Path.expand(root), @filename)

  @doc """
  What this working copy says about itself, or `:none`.

  The file is the only answer: no environment fallback, even when there is no
  file. A file that exists but cannot be read returns its error.
  See knowledge/harness, "Working-copy identity".
  """
  @spec read(String.t()) :: {:ok, t()} | :none | {:error, term()}
  def read(root) do
    root = Path.expand(root)

    from_file(root)
  end

  @doc """
  What `.cms_harness.json` says about this working copy. Same answer as
  `read/1`.
  """
  @spec read_file(String.t()) :: {:ok, t()} | :none | {:error, term()}
  def read_file(root), do: root |> Path.expand() |> from_file()

  @doc """
  Write what a working copy knows about itself.

  Returns `{:error, reason}` rather than raising: failing to persist is not a
  reason to stop serving this turn, but it does mean the next restart asks for
  a new id and orphans everything written under this one, so the caller has
  something to say about it.
  """
  @spec write(String.t(), t()) :: :ok | {:error, term()}
  def write(root, %{working_copy_id: id} = config) when is_binary(id) and id != "" do
    root = Path.expand(root)
    file = path(root)

    # Merged over the raw JSON, not the decoded map: other writers keep keys here
    # this module does not model (`preview_tunnel_secret` cannot be re-read).
    # See knowledge/harness, "Working-copy identity".
    body =
      root
      |> raw()
      |> Map.drop(
        ~w(harness_id working_copy_id root project_id deploy_key preview_url server_url)
      )
      |> Map.merge(%{working_copy_id: id, harness_id: id, root: root})
      |> merge_present(:project_id, config[:project_id] || recorded_value(root, :project_id))
      |> merge_present(:deploy_key, config[:deploy_key] || recorded_value(root, :deploy_key))
      |> merge_present(:preview_url, config[:preview_url] || recorded_value(root, :preview_url))
      # Which server minted this id; `Config.server_url/0` only knows the
      # reading build's server.
      |> merge_present(:server_url, config[:server_url] || recorded_value(root, :server_url))
      |> Jason.encode!(pretty: true)

    with :ok <- refuse_to_clobber(root, file),
         :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, body <> "\n"),
         # It holds a credential: keep it out of other accounts on the machine.
         :ok <- File.chmod(file, 0o600) do
      :ok
    else
      {:error, reason} ->
        Logger.error("""
        [CmsHarness] could not write #{file}: #{inspect(reason)}.

        This harness is serving normally, but a restart will be issued a second
        id and the files and problems recorded under this one will belong to
        nobody.
        """)

        {:error, reason}
    end
  end

  # A config that exists but cannot be read is reported as "not issued" by
  # `ProjectIdentity`, which means a mint can arrive for a copy that already has
  # one. Writing it would destroy the only record of the id its existing rows
  # are filed under. Refused, so the damage is one session rather than
  # permanent.
  defp refuse_to_clobber(root, file) do
    case from_file(root) do
      {:error, reason} ->
        Logger.error("""
        [CmsHarness] refusing to overwrite #{file}, which exists but could not be \
        read (#{inspect(reason)}).

        Writing a new id here would destroy the only record of the one this
        working copy's files and problems are already filed under. Fix the file's
        permissions, or delete it deliberately.
        """)

        {:error, :existing_identity_unreadable}

      _ ->
        :ok
    end
  end

  # The file exactly as it stands, string keys and all, or `%{}`. Not
  # `from_file/1`: a write must put back what this module does not understand.
  defp raw(root) do
    with {:ok, contents} <- File.read(path(root)),
         {:ok, %{} = map} <- Jason.decode(contents) do
      map
    else
      _ -> %{}
    end
  end

  # One of the keys this module does model, as previously recorded. Read through
  # the decoder so both the old and the new id spellings still resolve.
  defp recorded_value(root, key) do
    case from_file(root) do
      {:ok, config} -> Map.get(config, key)
      _ -> nil
    end
  end

  defp merge_present(map, _key, nil), do: map
  defp merge_present(map, _key, ""), do: map
  defp merge_present(map, key, value), do: Map.put(map, key, value)

  defp from_file(root) do
    case File.read(path(root)) do
      {:ok, contents} -> decode(contents, root)
      {:error, :enoent} -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  # Both `working_copy_id` and `harness_id` are read and written: older builds,
  # including the published `cms` binary, read the same file.
  # `working_copy_id` wins where both are present.
  defp decode(contents, root) do
    case Jason.decode(contents) do
      {:ok, map} ->
        map |> recorded_id() |> decoded(map, root)

      _ ->
        Logger.error("[CmsHarness] #{path(root)} is not a working copy config")
        {:error, :malformed}
    end
  end

  defp recorded_id(%{"working_copy_id" => id}) when is_binary(id) and id != "", do: id
  defp recorded_id(%{"harness_id" => id}) when is_binary(id) and id != "", do: id
  defp recorded_id(_map), do: nil

  defp decoded(nil, _map, root) do
    Logger.error("[CmsHarness] #{path(root)} is not a working copy config")
    {:error, :malformed}
  end

  defp decoded(id, map, root) do
    {:ok,
     %{
       working_copy_id: id,
       project_id: map["project_id"],
       deploy_key: map["deploy_key"],
       preview_url: map["preview_url"],
       server_url: map["server_url"],
       root: map["root"] || root
     }}
  end
end
