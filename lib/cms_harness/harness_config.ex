defmodule CmsHarness.HarnessConfig do
  @moduledoc """
  What a working copy knows about itself: which harness it is, and where.

  One file per working copy, at its root, and only one:

      {"working_copy_id": "…", "harness_id": "…", "project_id": "…", "root": "/abs/path"}

  Plus `deploy_key` once the copy has one, and `preview_url` on the copy that is
  the project's main checkout — the address its preview answers on, written at
  onboarding and reported to the server on join, the same way `root` is.

  There used to be two. `HarnessIdentity` wrote an id-only `.cms_working_copy_id`
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

    from_file(root)
  end

  # There is no environment fallback, deliberately.
  #
  # `read/1` used to fall back to `CMS_HARNESS_ID` when a root named no id of
  # its own. The variable belongs to whatever process started the daemon, and
  # the daemon serves every checkout on the machine — so one stale value in one
  # launching shell answered for all of them.
  #
  # That is not hypothetical. The daemon on this machine carried
  # `CMS_HARNESS_ID=6c4a7be3…`, the main checkout, while serving five roots that
  # each name themselves correctly in their own `.cms_harness.json`. Every
  # requirement row a worktree computed was written against main, and reading
  # its own answer back gave it main's — which is how a checkout whose spec
  # files were sitting right there was told they did not exist (`5b538c8b`).
  #
  # A checkout's identity is what its own file says. If the file says nothing,
  # that is a copy which has not been onboarded, and the honest answer is
  # `:none` — not a guess inherited from somebody's shell.
  #
  # `CMS_HARNESS_ID` still exists for exactly one consumer, and only that one:
  # the Claude Code MCP mount interpolates `${CMS_HARNESS_ID}` into an
  # `X-Harness-Id` header (`plugin.json`), because an `mcpServers` entry can
  # read an environment variable and cannot read a file. That client sends the
  # id explicitly; nothing here reads it.

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
  def write(root, %{working_copy_id: id} = config) when is_binary(id) and id != "" do
    root = Path.expand(root)
    file = path(root)

    # Merged over what the file literally says, not over what this module can
    # model. Callers supply the fields they know — `mint/1` knows the id and the
    # project, and nothing about the deploy key — and a write that dropped the
    # rest would take this copy's credential with it on the next mint.
    #
    # It used to merge over `recorded/1`, which round-trips through `decode/1`
    # and keeps five named keys. That is fine while this module is the only
    # writer and stopped being true when onboarding started putting the preview
    # credentials here: every write silently dropped `preview_tunnel_secret`,
    # which Cloudflare returns exactly once at creation and has no endpoint to
    # read back. The checkout kept running the tunnel it had already started, so
    # nothing looked wrong until something restarted.
    #
    # So the merge is over the raw JSON. A file shared with another writer has
    # to preserve what this side does not understand — including keys that do
    # not exist yet.
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
      # Which CodeMySpec minted this copy's id. Recorded because nothing else can
      # answer it: every tier of `Config.server_url/0` reports the *reading*
      # build's server, so a copy onboarded from a sibling checkout had no way to
      # say where it actually belongs, and its hooks 404ed against a daemon that
      # had never seen the row (a6d07cf3).
      |> merge_present(:server_url, config[:server_url] || recorded_value(root, :server_url))
      |> Jason.encode!(pretty: true)

    with :ok <- refuse_to_clobber(root, file),
         :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, body <> "\n"),
         # It holds a credential now, so it is not world-readable. The file is
         # gitignored, which keeps it out of the repository; this keeps it out of
         # other accounts on the machine.
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

  # What the file already says, as a plain map, or empty when there is none to
  # read. Deliberately not `from_file/1`'s error tuple: a caller here is about
  # to write, and `refuse_to_clobber/2` is what decides whether an unreadable
  # file may be replaced.
  # The file exactly as it stands, string keys and all. Deliberately not
  # `from_file/1`: that answers "what does this module understand", and a write
  # needs "what is actually in there" so it can put back what it does not.
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

  # Both key names are accepted, and that is the compatibility window.
  #
  # This file is on disk in every onboarded checkout, written by whichever build
  # onboarded it, and read by whichever build is running now — including the
  # published `cms` binary, which is not rebuilt when this repo is. So a reader
  # that understood only the new name would refuse every existing checkout, and
  # a writer that emitted only the new name would break the published binary
  # reading the same file. Both sides accept both until nothing old is left.
  #
  # `working_copy_id` wins where both are present: it is what a current build
  # wrote, and a stale `working_copy_id` beside it is the older of the two.
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

  defp present_or_none(""), do: :none
  defp present_or_none(id), do: {:ok, id}
end
