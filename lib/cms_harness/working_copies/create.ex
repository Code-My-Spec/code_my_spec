defmodule CmsHarness.WorkingCopies.Create do
  @moduledoc """
  Making a checkout on this machine, because this is the machine with the disk.

  The server owns the record and cannot run `git worktree add` — it is not on
  this filesystem, and `fs_request` is scoped to one project root so it could
  not make a *sibling* even if it were. So the file half happens here and the
  record half happens there, and the caller made one call (story 891, rule "The
  harness does the work on disk and the server does the work on the record").

  Beside `CmsHarness.WorkingCopies` rather than inside it: that module answers
  *which copy an id names*, from configs already on disk, and needs no network
  and no repository. This runs git and writes into a new directory. One is a
  lookup and the other is an act.

  ## A worktree, not a clone

  A worktree shares the repository's object store, so making one costs a
  checkout of the tree rather than a copy of the history. That is the difference
  between a second and a minute here, and the whole point of the copy is that an
  agent can have one whenever there is work for it.

  It also keeps the copies on one filesystem, which is what lets the server key
  them on `(device_id, root)`. Two machines share a path constantly — every
  container at `/workspace/app` — and a clone somewhere else would need its own
  device before it meant anything.

  ## Identity is written here

  `.cms_harness.json` is what makes the directory a working copy rather than a
  directory. The id travels *in* with the request rather than back out with the
  reply, so what the server records and what the disk says are the same value
  rather than two derivations of it — which is the failure story 891 exists to
  end, and its notes list four of them by name.
  """

  require Logger

  @worktrees ".claude/worktrees"

  @doc """
  Make a working copy beside `root` and give it an identity.

  Answers `{:ok, %{root:, working_copy_id:}}`, or `{:error, reason}` with
  nothing left behind that claims to be a working copy.
  """
  @spec run(String.t(), map()) ::
          {:ok, %{root: String.t(), working_copy_id: String.t()}} | {:error, term()}
  def run(root, request) when is_binary(root) and root != "" do
    name = slug(request["label"])
    target = request["root"] || Path.join([root, @worktrees, name])

    with :ok <- refuse_existing(target),
         :ok <- add_worktree(root, target, name),
         {:ok, id} <- write_identity(target, request) do
      Logger.info("[CmsHarness] made a working copy at #{target}")
      {:ok, %{root: target, working_copy_id: id}}
    end
  end

  def run(_root, _request), do: {:error, :no_repository}

  # A directory that is already there is not ours to take. It may hold somebody's
  # work, and adopting it would give two copies one path.
  defp refuse_existing(target) do
    if File.exists?(target), do: {:error, {:already_exists, target}}, else: :ok
  end

  # `-b` so the copy gets its own branch. Two worktrees cannot check out the same
  # branch, and an epic's copy sharing one with the main checkout would mean every
  # commit on either appears on both — the opposite of the boundary the copy
  # exists to draw.
  defp add_worktree(root, target, name) do
    File.mkdir_p!(Path.dirname(target))

    case System.cmd("git", ["worktree", "add", "-b", name, target],
           cd: root,
           stderr_to_stdout: true
         ) do
      {_out, 0} -> :ok
      {out, status} -> {:error, {:worktree_failed, status, String.trim(out)}}
    end
  end

  defp write_identity(target, request) do
    id = request["working_copy_id"] || Ecto.UUID.generate()

    body =
      %{
        "working_copy_id" => id,
        "harness_id" => id,
        "project_id" => request["project_id"],
        "root" => target
      }
      |> maybe_put("deploy_key", request["deploy_key"])
      |> maybe_put("server_url", request["server_url"])
      |> Jason.encode!(pretty: true)

    case File.write(Path.join(target, ".cms_harness.json"), body <> "\n") do
      :ok -> {:ok, id}
      {:error, reason} -> {:error, {:identity_not_written, reason}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # A directory name a person can read, from the label they gave. Falls back to
  # something unique rather than refusing — a copy with an awkward name is worth
  # more than no copy.
  defp slug(label) when is_binary(label) and label != "" do
    label
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> unique_name()
      slug -> String.slice(slug, 0, 40)
    end
  end

  defp slug(_label), do: unique_name()

  defp unique_name, do: "copy-#{System.unique_integer([:positive])}"
end
