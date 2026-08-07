defmodule CmsHarness.HarnessIdentity do
  @moduledoc """
  Which *harness* this is — one per working copy.

  Distinct from `ProjectIdentity`, and the distinction is the whole point. A
  project id says which project a directory belongs to and is shared by every
  checkout of it; a harness id says which checkout, and no two share one. Files
  and problems are statements about a working copy, so they belong to the
  second.

  ## The server issues it, this only keeps it

  The harness announces its root, the server mints an id, and this writes it
  down so a restart presents the same one. Nothing here generates an id.

  That is deliberate and it was the decided question on story 727. Every
  client-derived alternative fails a real case: a checkout path collides when
  two containers both sit at `/workspace/app`; host+path collides for exactly
  the containers whose hostnames are generated; a session id churns and would
  split a parent agent from its subagents. A local agent and a cloud agent on
  the same branch — different uncommitted state, different machines — is the
  case that decides it, and nothing derivable from the checkout alone survives
  it.

  ## Never committed

  A committed id is cloned into every checkout, so a sprite cloning the repo
  comes up wearing the laptop's identity and both sync into the same rows —
  the corruption the lease exists to prevent, with no lease left. It lives at
  the working-copy root and the repo ignores it.

  Not under `.code_my_spec/`, where `ProjectIdentity` reads its config, even
  though that reads like the tidy home for it: that directory is a git
  submodule pointing at the docs repo, so a file placed there is untracked in
  *this* repo but stageable in that one. An id committed to the docs repo would
  be inherited by everyone who clones it, which is the failure this is against.

  A working copy with no id file has not been issued one yet. That is an
  ordinary state — the first join is what mints it — so it is `:none` rather
  than an error.
  """

  require Logger

  @filename ".cms_harness_id"

  @type t :: String.t()

  @doc "Where the id lives for a working copy."
  @spec path(String.t()) :: String.t()
  def path(root), do: Path.join(Path.expand(root), @filename)

  @doc """
  The id this working copy has been issued, if any.

  `:none` covers "never issued" and "the file was removed" alike — both mean
  the next join has to ask for one, and neither is an error.

  A file that exists but cannot be read is neither: something is there and this
  cannot tell what. It returns `{:error, reason}`, which the caller must not
  treat as "not issued" — asking for a second id would strand every row written
  under the first, and doing that silently is worse than serving without one.
  """
  @spec read(String.t()) :: {:ok, t()} | :none | {:error, term()}
  def read(root) do
    file = path(root)

    case File.read(file) do
      {:ok, contents} -> from_contents(contents)
      {:error, :enoent} -> :none
      {:error, reason} -> unreadable(file, reason)
    end
  end

  @doc """
  Write down the id the server issued.

  Returns `{:error, reason}` rather than raising: failing to persist is not a
  reason to stop serving this turn, but it does mean the next restart asks for
  a new id and orphans everything written under this one, so the caller has
  something to say about it.
  """
  @spec write(String.t(), t()) :: :ok | {:error, term()}
  def write(root, id) when is_binary(id) and id != "" do
    file = path(root)

    with :ok <- refuse_to_clobber(root, file),
         :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, id <> "\n") do
      :ok
    else
      {:error, reason} ->
        Logger.error("""
        [CmsHarness] could not write the harness id to #{file}: #{inspect(reason)}.

        This harness is serving normally, but a restart will be issued a second
        id and the files and problems recorded under this one will belong to
        nobody.
        """)

        {:error, reason}
    end
  end

  # An id file that exists but cannot be read is reported as "not issued" by
  # `ProjectIdentity`, which means a mint can arrive for a copy that already has
  # one. Writing it would destroy the only record of the id its existing rows
  # are filed under. Refused, so the damage is one session rather than permanent.
  defp refuse_to_clobber(root, file) do
    case read(root) do
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

  defp from_contents(contents) do
    case String.trim(contents) do
      "" -> :none
      id -> {:ok, id}
    end
  end

  defp unreadable(file, reason) do
    Logger.error("""
    [CmsHarness] #{file} exists but could not be read: #{inspect(reason)}.

    This working copy has an identity and cannot present it. Reporting it as
    unidentified would ask the server for a second id and strand everything
    recorded under the first, so this refuses instead. Fix the file's
    permissions, or delete it to be issued a new one deliberately.
    """)

    {:error, reason}
  end
end
