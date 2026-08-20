defmodule CmsHarness.HarnessConfig do
  @moduledoc """
  What a working copy knows about itself: which harness it is, and where.

  One file per working copy, at its root, and only one:

      {"harness_id": "…", "project_id": "…", "root": "/abs/path"}

  There used to be two. `HarnessIdentity` wrote an id-only `.cms_harness_id`
  when the server issued one, this wrote `.cms_harness.json` at onboarding, and
  a working copy that had been through both carried two files naming two
  harnesses with nothing on disk saying which counted. Reading preferred the
  JSON, so behaviour was never ambiguous — but the first person to look at the
  directory concluded they disagreed, which is cost enough. There is no fallback
  now, and no second writer.

  ## Why the root is in here

  Because otherwise something has to discover it, and every way of discovering
  it has been wrong. Walking up from the directory a hook fired in resolved one
  session differently depending on the subdirectory, and resolved a nested
  checkout to the outer one. A list of directories in the environment put the
  operator back in the business of registering paths. A lookup against the
  server made the harness unable to answer until the network came up, and
  duplicated a record the server already holds.

  A working copy knows where it is. Writing that down when we mint its identity
  costs nothing and removes all three.

  The server keeps the same fact on the harness record, reported on join. That
  is not a second source of truth — it is the same fact, in the place an
  operator looks at harnesses rather than the place a harness looks at itself.

  ## Never committed

  A committed harness id is cloned into every checkout, so a sprite that clones
  the repo comes up wearing the laptop's identity and both sync into the same
  rows. The file is gitignored, and it lives at the working-copy root rather
  than under `.code_my_spec/`, which is a submodule pointing at the docs repo —
  a file placed there is untracked here and stageable there.
  """

  require Logger

  @filename ".cms_harness.json"
  @env_var "CMS_HARNESS_ID"

  @type t :: %{harness_id: String.t(), project_id: String.t() | nil, root: String.t()}

  @doc "Where the config lives for a working copy."
  @spec path(String.t()) :: String.t()
  def path(root), do: Path.join(Path.expand(root), @filename)

  @doc """
  What this working copy says about itself, or `:none`.

  The file is the answer. `CMS_HARNESS_ID` is consulted only when there is no
  file at all — a container or sprite that was handed an id and has nowhere to
  have stored it.

  ## The env used to win, and it collapsed every root onto one id

  Onboarding writes `CMS_HARNESS_ID` into each checkout's
  `.claude/settings.local.json`, because the Claude Code MCP mount interpolates
  environment variables and cannot read a file — that one consumer is the whole
  reason the variable exists. A session in worktree W therefore carries `id(W)`,
  and `just refresh-harness` is designed to be launched from any session, so the
  daemon it starts inherits it.

  That daemon serves several roots and calls this once per root. With the env
  checked first, every root answered `id(W)`. On the server they then presented
  one id from one OS process, which `Analysis.take_over/3` reads as a harness
  reconnecting to its own slot — so each join killed the previous one. Measured:
  1078 evictions, roughly one every 1.4 seconds, every stop hook refused, until
  the daemon was restarted with the variable stripped.

  Inverting costs nothing for a correctly onboarded copy, because onboarding
  writes the *same* id to `.cms_harness.json` and to `settings.local.json`. The
  two differ only when something has gone wrong, and there the file is right: it
  is the one that knows which working copy it is sitting in.

  A file that exists but cannot be read returns its error rather than falling
  through to the environment. Substituting another working copy's id for a
  broken config is precisely the failure this ordering exists to prevent, and it
  is worse than saying so — `write/2` already refuses to overwrite a malformed
  config for the same reason.
  """
  @spec read(String.t()) :: {:ok, t()} | :none | {:error, term()}
  def read(root) do
    root = Path.expand(root)

    case from_file(root) do
      {:ok, config} -> {:ok, config}
      :none -> from_env_config(root)
      {:error, reason} -> {:error, reason}
    end
  end

  defp from_env_config(root) do
    case from_env() do
      {:ok, id} -> {:ok, %{harness_id: id, project_id: nil, root: root}}
      :none -> :none
    end
  end

  @doc """
  What `.cms_harness.json` itself says about this working copy, ignoring
  `CMS_HARNESS_ID`.

  For callers resolving *this specific root's* own identity — never for
  enumerating several roots at once, where the env override would make every
  one of them answer with the same id. See `read/1`'s doc.
  """
  @spec read_file(String.t()) :: {:ok, t()} | :none | {:error, term()}
  def read_file(root), do: root |> Path.expand() |> from_file()

  @doc """
  The id the environment names, if it names one.

  Separate from `read/1` so a caller deciding whether to persist can tell an
  injected id from a stored one.
  """
  @spec from_env() :: {:ok, String.t()} | :none
  def from_env do
    case System.get_env(@env_var) do
      nil -> :none
      value -> value |> String.trim() |> present_or_none()
    end
  end

  @doc """
  Write what a working copy knows about itself.

  Returns `{:error, reason}` rather than raising: failing to persist is not a
  reason to stop serving this turn, but it does mean the next restart asks for
  a new id and orphans everything written under this one, so the caller has
  something to say about it.
  """
  @spec write(String.t(), t()) :: :ok | {:error, term()}
  def write(root, %{harness_id: id} = config) when is_binary(id) and id != "" do
    root = Path.expand(root)
    file = path(root)

    body =
      %{harness_id: id, project_id: config[:project_id], root: root}
      |> Jason.encode!(pretty: true)

    with :ok <- refuse_to_clobber(root, file),
         :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, body <> "\n") do
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
  #
  # Checks the file rather than `read/1`: an id injected by `CMS_HARNESS_ID`
  # says nothing about what is on disk, and letting it answer here would report
  # "nothing stored" for a copy whose file is merely unreadable.
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

  defp from_file(root) do
    case File.read(path(root)) do
      {:ok, contents} -> decode(contents, root)
      {:error, :enoent} -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(contents, root) do
    case Jason.decode(contents) do
      {:ok, %{"harness_id" => id} = map} when is_binary(id) and id != "" ->
        {:ok, %{harness_id: id, project_id: map["project_id"], root: map["root"] || root}}

      _ ->
        Logger.error("[CmsHarness] #{path(root)} is not a harness config")
        {:error, :malformed}
    end
  end

  defp present_or_none(""), do: :none
  defp present_or_none(id), do: {:ok, id}
end
