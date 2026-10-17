defmodule CmsHarness.WorkingCopies.SyncToMain do
  @moduledoc """
  Bringing this checkout's branch up to date with its remote's main, because
  this is the machine with the disk.

  Fast-forward only, and refused on a dirty tree. A working copy exists to
  hold one agent's own work; neither a real merge nor a merge into
  uncommitted changes is a decision this call gets to make on that agent's
  behalf. Both refuse before anything is written, with the git output that
  explains why (8f5ebfb2: nothing reachable could bring a stale working
  copy's checkout up to date before staffing it).
  """

  @doc """
  Fetch `payload["remote"]` (default `"origin"`) and fast-forward merge
  `payload["branch"]` (default `"main"`) into `root`.

  Answers `{:ok, %{from:, to:, updated:}}` with the commits before and after,
  or `{:error, %{tag:, detail:}}` -- a map, never a bare tuple, because the
  reply travels as JSON and a tuple there crashes the channel that carries it.
  """
  @spec run(String.t(), map()) :: {:ok, map()} | {:error, %{tag: atom(), detail: String.t()}}
  def run(root, payload) when is_binary(root) and root != "" do
    remote = payload["remote"] || "origin"
    branch = payload["branch"] || "main"

    with :ok <- clean?(root),
         {:ok, before} <- head(root),
         :ok <- fetch(root, remote),
         {:ok, after_sha} <- merge(root, remote, branch) do
      {:ok, %{from: before, to: after_sha, updated: before != after_sha}}
    end
  end

  defp clean?(root) do
    case git(root, ["status", "--porcelain"]) do
      {"", 0} ->
        :ok

      {_dirty, 0} ->
        {:error,
         %{
           tag: :dirty_tree,
           detail: "this checkout has uncommitted changes; sync refused rather than merging into them"
         }}

      {out, status} ->
        git_error(:status_failed, status, out)
    end
  end

  defp head(root) do
    case git(root, ["rev-parse", "HEAD"]) do
      {sha, 0} -> {:ok, String.trim(sha)}
      {out, status} -> git_error(:rev_parse_failed, status, out)
    end
  end

  defp fetch(root, remote) do
    case git(root, ["fetch", remote]) do
      {_out, 0} -> :ok
      {out, status} -> git_error(:fetch_failed, status, out)
    end
  end

  defp merge(root, remote, branch) do
    case git(root, ["merge", "--ff-only", "#{remote}/#{branch}"]) do
      {_out, 0} -> head(root)
      {out, status} -> git_error(:not_fast_forward, status, out)
    end
  end

  defp git(root, args), do: System.cmd("git", ["-C", root] ++ args, stderr_to_stdout: true)

  defp git_error(tag, status, out) do
    {:error, %{tag: tag, detail: "git exited #{status}: #{String.trim(out)}"}}
  end
end
