defmodule CmsHarness.WorkingCopies do
  @moduledoc """
  The working copies this machine knows about, by id.

  A hook names a harness id and nothing else. Resolving that to a directory
  needs a map, and this is it — a file this project writes and reads, in a
  format this project decides.

  ## Why not ask the agent

  The previous answer was the directory the agent announced, which coupled
  identity to the agent twice over: to the path it happened to be in, and to
  the agent's own configuration format for saying so. Claude Code interpolates
  `${CLAUDE_PROJECT_DIR}` into a hook argument; Codex and Antigravity do
  neither, and we ship plugins for all three. Any identity that travels through
  the agent is three mechanisms pretending to be one, and it makes somebody
  else's config format part of our contract.

  So the id is written into the hook URL when a working copy is onboarded, and
  the mapping from that id to a directory lives here. Nothing is resolved at
  request time from anything the agent controls.

  ## Why a file rather than the database

  This has to answer before the first hook of a cold start, when nothing is
  connected and there may be no server to ask. It is also the thing that tells
  the harness which directories to serve at all, so making it a query would
  mean the harness could not start without the network.

  Entries are added deliberately, by onboarding. A directory that is not in
  here is not served, and a hook naming an unknown id is refused by name rather
  than guessed at — which is the whole difference from what this replaces.
  """

  require Logger

  @filename "harnesses.json"

  @type t :: %{String.t() => String.t()}

  @doc "Where the map lives. `CMS_HARNESS_REGISTRY` overrides it, for tests."
  @spec path() :: String.t()
  def path do
    System.get_env("CMS_HARNESS_REGISTRY") ||
      Path.join(base_dir(), @filename)
  end

  @doc """
  Every known working copy, as `id => root`.

  A missing file is an empty map: a machine that has never onboarded anything
  is an ordinary state, not a failure. A *corrupt* file is not — it means
  entries exist and cannot be read, so it says so and returns empty rather than
  letting a hook fall through to being told its id is unknown.
  """
  @spec all() :: t()
  def all do
    file = path()

    case File.read(file) do
      {:error, :enoent} ->
        %{}

      {:ok, contents} ->
        decode(contents, file)

      {:error, reason} ->
        Logger.error("[CmsHarness] could not read #{file}: #{inspect(reason)}")
        %{}
    end
  end

  @doc "The directory this id names, if this machine knows it."
  @spec root(String.t()) :: {:ok, String.t()} | :unknown
  def root(harness_id) when is_binary(harness_id) do
    case Map.fetch(all(), harness_id) do
      {:ok, root} -> {:ok, root}
      :error -> :unknown
    end
  end

  def root(_), do: :unknown

  @doc """
  Record that `harness_id` is the working copy at `root`.

  Last write wins for a given id, because a checkout that moves keeps its
  identity — that is what the id being independent of the path buys. Two ids
  pointing at one root is allowed for the same reason it is allowed on the
  server: a directory reused by a rebuilt container is a new working copy, and
  refusing that here would only push the collision somewhere less visible.
  """
  @spec put(String.t(), String.t()) :: :ok | {:error, term()}
  def put(harness_id, root) when is_binary(harness_id) and is_binary(root) do
    entries = Map.put(all(), harness_id, Path.expand(root))

    write(entries)
  end

  @doc "Forget a working copy. Onboarding is deliberate, so removal is too."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(harness_id) when is_binary(harness_id) do
    all() |> Map.delete(harness_id) |> write()
  end

  defp write(entries) do
    file = path()

    with :ok <- File.mkdir_p(Path.dirname(file)),
         {:ok, json} <- Jason.encode(entries, pretty: true),
         :ok <- File.write(file, json <> "\n") do
      :ok
    else
      {:error, reason} ->
        Logger.error("""
        [CmsHarness] could not write #{file}: #{inspect(reason)}.

        Working copies onboarded in this session will not be served after a
        restart, and their hooks will be refused as unknown ids.
        """)

        {:error, reason}
    end
  end

  defp decode(contents, file) do
    case Jason.decode(contents) do
      {:ok, %{} = entries} ->
        entries

      _ ->
        Logger.error("""
        [CmsHarness] #{file} is not a JSON object of id => root.

        Every hook will be refused as an unknown id until this is fixed. The
        file is not rewritten, so whatever is in there can be recovered.
        """)

        %{}
    end
  end

  defp base_dir do
    Path.join(System.user_home!(), ".codemyspec")
  end
end
