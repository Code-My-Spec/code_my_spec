defmodule CodeMySpec.Promotion.StepsTest do
  @moduledoc """
  A repo already mid-merge refuses a new `git merge` outright, and the code
  used to read that refusal the same way it reads a fresh conflict —
  re-running `git status --porcelain` and naming whatever it found as though
  this merge had just produced it. A conflict resolved in content but never
  staged reads as a clean tree to `--porcelain`, so the message pointed at a
  file with nothing wrong with it, hours after the promotion that actually
  left the merge in progress (e17d3946).
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Promotion.Steps
  alias CodeMySpec.TempFile

  defp git!(env, root, args) do
    {out, 0} = Environments.cmd(env, "git", args, cd: root, stderr_to_stdout: true)
    out
  end

  defp write(root, path, content) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  # Two branches that conflict on the same file, neither merged into the
  # other yet — the state a checkout is in the moment before a promotion's
  # own `git merge` runs.
  defp a_repo_with_diverging_branches(prefix) do
    root = TempFile.dir(prefix)
    File.mkdir_p!(root)
    env = Environment.new(:local, root)

    git!(env, root, ["init", "-q", "--initial-branch", "main"])
    git!(env, root, ["config", "user.email", "test@example.com"])
    git!(env, root, ["config", "user.name", "Test"])

    write(root, "war.ex", "defmodule War do\n  def declare, do: :base\nend\n")
    git!(env, root, ["add", "-A"])
    git!(env, root, ["commit", "-q", "-m", "base"])

    git!(env, root, ["checkout", "-q", "-b", "story/war"])
    write(root, "war.ex", "defmodule War do\n  def declare, do: :from_the_story\nend\n")
    git!(env, root, ["commit", "-q", "-am", "the story's work"])

    git!(env, root, ["checkout", "-q", "main"])
    write(root, "war.ex", "defmodule War do\n  def declare, do: :from_main\nend\n")
    git!(env, root, ["commit", "-q", "-am", "somebody else's work"])

    {env, root}
  end

  describe "merge/3" do
    test "a fresh conflict is reported and left for the agent to resolve" do
      {env, root} = a_repo_with_diverging_branches("steps-test-fresh-conflict")

      assert {:error, %{reason: reason, conflicts: conflicts}} =
               Steps.merge(env, root, "story/war")

      assert reason =~ "war.ex"
      assert conflicts == ["war.ex"]

      {status, 0} = Environments.cmd(env, "git", ["status", "--porcelain"], cd: root)
      assert status =~ ~r/^(UU|AA)/m, "the conflict was cleaned up instead of left to resolve"
    end

    test "a merge already in progress is named as such, not as a fresh conflict" do
      {env, root} = a_repo_with_diverging_branches("steps-test-stale-merge")

      # A first promotion attempt conflicts, exactly as the test above
      # confirms, and leaves the merge in progress.
      assert {:error, %{conflicts: ["war.ex"]}} = Steps.merge(env, root, "story/war")

      # The agent resolves the conflict in content and never stages it —
      # exactly the state the issue measured: `git status --porcelain` reads
      # clean while `MERGE_HEAD` still stands.
      write(root, "war.ex", "defmodule War do\n  def declare, do: :resolved\nend\n")

      {status, 0} = Environments.cmd(env, "git", ["status", "--porcelain"], cd: root)

      assert status =~ ~r/^(UU|AA)/m,
             "premise failed: the conflict marker should still show before staging"

      # A second promotion attempt against the same still-unresolved merge.
      assert {:error, %{reason: reason, stale_merge: true}} =
               Steps.merge(env, root, "story/war")

      assert reason =~ "already in progress",
             "the message should name the actual state rather than reporting a fresh conflict"

      refute reason =~ "war.ex",
             "the stale-merge message should not send a reader to a file that is fine — " <>
               "that is the exact cost this fix exists to end"

      {sha, 0} = Environments.cmd(env, "git", ["rev-parse", "story/war"], cd: root)
      assert reason =~ String.trim(sha), "the message should name the sha it is stuck against"
    end

    test "a merge that succeeds cleanly reports the merge output" do
      root = TempFile.dir("steps-test-clean-merge")
      File.mkdir_p!(root)
      env = Environment.new(:local, root)

      git!(env, root, ["init", "-q", "--initial-branch", "main"])
      git!(env, root, ["config", "user.email", "test@example.com"])
      git!(env, root, ["config", "user.name", "Test"])

      write(root, "a.ex", "1\n")
      git!(env, root, ["add", "-A"])
      git!(env, root, ["commit", "-q", "-m", "base"])

      git!(env, root, ["checkout", "-q", "-b", "story/feature"])
      write(root, "b.ex", "2\n")
      git!(env, root, ["add", "-A"])
      git!(env, root, ["commit", "-q", "-m", "the story's work"])
      git!(env, root, ["checkout", "-q", "main"])

      assert {:ok, %{output: _output}} = Steps.merge(env, root, "story/feature")
      assert File.exists?(Path.join(root, "b.ex"))
    end
  end
end
