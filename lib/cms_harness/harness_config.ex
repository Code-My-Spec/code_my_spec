defmodule CmsHarness.HarnessConfig do
  @moduledoc """
  What a working copy knows about itself: which harness it is, and where.

  Minted by `mix cms.harness.onboard` and never committed. One file per working
  copy, at its root:

      {"harness_id": "…", "project_id": "…", "root": "/abs/path"}

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
  @legacy_filename ".cms_harness_id"

  @type t :: %{harness_id: String.t(), project_id: String.t() | nil, root: String.t()}

  @doc "Where the config lives for a working copy."
  @spec path(String.t()) :: String.t()
  def path(root), do: Path.join(Path.expand(root), @filename)

  @doc """
  What this working copy says about itself, or `:none`.

  Falls back to the legacy id-only file so a copy onboarded before this existed
  keeps working — it yields an id and takes the root from where the file was
  found, which is the same answer.
  """
  @spec read(String.t()) :: {:ok, t()} | :none | {:error, term()}
  def read(root) do
    root = Path.expand(root)

    case File.read(path(root)) do
      {:ok, contents} -> decode(contents, root)
      {:error, :enoent} -> legacy(root)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Write what a working copy knows about itself."
  @spec write(String.t(), t()) :: :ok | {:error, term()}
  def write(root, %{harness_id: id} = config) when is_binary(id) and id != "" do
    root = Path.expand(root)

    body =
      %{harness_id: id, project_id: config[:project_id], root: root}
      |> Jason.encode!(pretty: true)

    case File.write(path(root), body <> "\n") do
      :ok ->
        drop_legacy(root)
        :ok

      {:error, reason} ->
        Logger.error("""
        [CmsHarness] could not write #{path(root)}: #{inspect(reason)}.

        This working copy cannot say which harness it is, so its hooks will be
        refused until it can.
        """)

        {:error, reason}
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

  # Writing the current file completes the migration, which means removing the
  # one it replaces. Leaving it behind is how a working copy ends up carrying
  # two identities: devops-qa held `.cms_harness_id` naming 5d5c599b beside a
  # `.cms_harness.json` naming 8a663385, with nothing on disk saying which won.
  # `read/1` has always preferred the JSON, so the behaviour was never in doubt
  # — but anyone reading the directory has to know that, and the first person to
  # look concluded the two disagreed.
  #
  # Failure to remove it is not a failure to write the identity, so it is logged
  # and swallowed.
  defp drop_legacy(root) do
    file = Path.join(root, @legacy_filename)

    case File.rm(file) do
      :ok ->
        Logger.info("[CmsHarness] removed the legacy #{@legacy_filename} in #{root}")

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("""
        [CmsHarness] wrote #{path(root)} but could not remove the legacy #{file}: \
        #{inspect(reason)}. Both files now name this working copy; the JSON is the \
        one that counts.\
        """)
    end
  end

  # The id-only file this replaces. Its root is where it was found, which is the
  # same thing the new file records.
  #
  # Said out loud once per root. A working copy on the legacy file has no
  # `project_id` and will not be migrated until something writes its config, and
  # neither fact is visible from a hook that simply works.
  defp legacy(root) do
    case File.read(Path.join(root, @legacy_filename)) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" ->
            :none

          id ->
            warn_legacy_once(root)
            {:ok, %{harness_id: id, project_id: nil, root: root}}
        end

      {:error, :enoent} ->
        :none

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `read/1` runs on every hook, so this cannot log per call. Same
  # `:persistent_term` shape `Sync` and `TestDatabase` already use for
  # once-per-root facts.
  defp warn_legacy_once(root) do
    key = {__MODULE__, :legacy_warned, root}

    if :persistent_term.get(key, nil) == nil do
      :persistent_term.put(key, true)

      Logger.info("""
      [CmsHarness] #{root} identifies itself with the legacy #{@legacy_filename}. \
      It carries no project id, and it will keep being used until something writes \
      #{@filename} — `mix cms.harness.onboard` does.\
      """)
    end
  end
end
