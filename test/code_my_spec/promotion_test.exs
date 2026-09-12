defmodule CodeMySpec.PromotionTest do
  @moduledoc """
  Where a promotion's disk work runs, and what it does when it cannot run.

  Every spec in story 1046 builds `Environment.new(:local, root)` and drives a
  real checkout on the machine running the suite. Production does not look like
  that: a project's checkout is on someone else's machine, `scope.environment`
  is a harness environment, and `Environments.Harness.cmd/4` answers
  `{:error, :not_supported_on_harness}` — it carries file operations to the
  disk, not commands.

  So the one environment that matters was the one nothing covered, and the
  tool's first real invocation crashed with `-32603 Internal error`:
  `String.trim(:error)`, from a caller assuming `cmd/4` always answers
  `{binary, status}`.

  `Promotion.Runner` is the answer — the gate stays on the server where the
  database is, and the three disk operations run wherever the checkout is.
  These cover the paths that have no disk to reach.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Promotion.{Runner, Steps}

  describe "a runner with nowhere to run" do
    test "a harness environment with no working copy id says so" do
      scope = %{full_scope_fixture() | environment: Environment.new(:harness, nil)}

      assert {:error, %{reason: reason}} = Runner.precheck(scope, "/somewhere", nil)

      assert reason =~ "working copy id",
             "the harness is addressed by id, not by path — a missing id has to " <>
               "name itself rather than surface as a failed lookup. Got: #{reason}"
    end

    test "a harness that is not connected is reported, not crashed into" do
      scope = %{full_scope_fixture() | environment: Environment.new(:harness, nil)}

      assert {:error, %{reason: reason}} =
               Runner.restart(scope, "/somewhere", Ecto.UUID.generate())

      assert reason =~ "could not reach",
             "an unreachable machine is a state to report, not an exception. " <>
               "Got: #{reason}"
    end

    test "a scope with no environment at all is refused" do
      scope = %{full_scope_fixture() | environment: nil}

      assert {:error, %{reason: reason}} = Runner.merge(scope, "/somewhere", "main", nil)
      assert reason =~ "no environment"
    end
  end

  describe "a command that errors instead of running" do
    # The exact crash. `Environments.cmd(nil, ...)` answers `{"no environment", 1}`
    # and a harness environment answers `{:error, :not_supported_on_harness}`;
    # `Steps` has to survive both without trimming an atom.
    test "does not raise out of a step" do
      assert {:error, %{reason: reason}} = Steps.precheck(nil, "/nowhere")
      assert is_binary(reason)
    end

    test "a step handed a harness environment reports rather than raises" do
      env = Environment.new(:harness, nil)

      assert {:error, %{reason: reason}} = Steps.precheck(env, "/nowhere")

      assert is_binary(reason),
             "this is the call that produced `String.trim(:error)` and a -32603 " <>
               "on the tool's first real use"
    end
  end

  describe "a merge already in progress" do
    setup do
      {:ok, root} = Briefly.create(directory: true)
      git = fn args -> System.cmd("git", args, cd: root, stderr_to_stdout: true) end

      {_, 0} = git.(["init", "--initial-branch=main"])
      {_, 0} = git.(["config", "user.email", "t@example.com"])
      {_, 0} = git.(["config", "user.name", "T"])

      File.write!(Path.join(root, "f.txt"), "base\n")
      {_, 0} = git.(["add", "."])
      {_, 0} = git.(["commit", "-m", "base"])

      {_, 0} = git.(["checkout", "-b", "side"])
      File.write!(Path.join(root, "f.txt"), "side\n")
      {_, 0} = git.(["commit", "-am", "side"])

      {_, 0} = git.(["checkout", "main"])
      File.write!(Path.join(root, "f.txt"), "main\n")
      {_, 0} = git.(["commit", "-am", "main"])

      # The half-merge. Conflicts, and is left exactly as a failed promotion
      # leaves it.
      {_, code} = git.(["merge", "--no-edit", "side"])
      assert code != 0

      %{root: root, git: git, env: Environment.new(:local, root)}
    end

    test "one whose conflicts are resolved is concluded, and the new merge runs",
         %{root: root, env: env} do
      # Somebody resolved it and never staged it — which is the state the
      # running copy was actually found in.
      File.write!(Path.join(root, "f.txt"), "resolved\n")

      assert {:ok, _} = Steps.merge(env, root, "side")

      {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: root)

      assert status == "",
             """
             The earlier merge was left in progress. While MERGE_HEAD exists no
             promotion can merge anything, so this is not a tidiness point — it
             is the difference between a pipeline that moves and one that
             reports the same stale file forever.

             status:
             #{status}
             """
    end

    test "one still carrying markers is refused, and says a merge is in progress",
         %{root: root, env: env} do
      assert {:error, %{reason: reason}} = Steps.merge(env, root, "side")

      assert reason =~ "still in a merge from an earlier promotion",
             """
             The refusal describes a fresh conflict in a file. It is neither: no
             merge was attempted, and the file has been sitting there since the
             promotion that did conflict.

             Naming the file sends the reader to the file, which is where eight
             hours went. Got: #{reason}
             """
    end
  end

  describe "a fresh conflict" do
    setup do
      {:ok, root} = Briefly.create(directory: true)
      git = fn args -> System.cmd("git", args, cd: root, stderr_to_stdout: true) end

      {_, 0} = git.(["init", "--initial-branch=main"])
      {_, 0} = git.(["config", "user.email", "t@example.com"])
      {_, 0} = git.(["config", "user.name", "T"])

      File.write!(Path.join(root, "f.txt"), "base\n")
      {_, 0} = git.(["add", "."])
      {_, 0} = git.(["commit", "-m", "base"])

      {_, 0} = git.(["checkout", "-b", "side"])
      File.write!(Path.join(root, "f.txt"), "side\n")
      {_, 0} = git.(["commit", "-am", "side"])

      {_, 0} = git.(["checkout", "main"])
      File.write!(Path.join(root, "f.txt"), "main\n")
      {_, 0} = git.(["commit", "-am", "main"])

      %{root: root, git: git, env: Environment.new(:local, root)}
    end

    # bed1d974: a conflict used to stay in the running checkout for the agent
    # to resolve there. Measured cost: a worktree six commits behind main
    # wedged the shared dev checkout from 00:28 to 10:40 merging unattended —
    # the identical conflict, merged main-first in the worktree instead,
    # resolved in two minutes with a test suite behind it. Aborting and
    # naming the file sends the agent back to do that, rather than leaving
    # the shared checkout mid-merge for however long that takes.
    test "is aborted, names the file, and leaves the checkout exactly as it was",
         %{root: root, git: git, env: env} do
      assert {:error, %{reason: reason, conflicts: ["f.txt"]}} = Steps.merge(env, root, "side")

      assert reason =~ "f.txt",
             "the agent has to know what conflicted to resolve it locally. Got: #{reason}"

      assert reason =~ "Merge main",
             "the remedy is the agent's to run, in its own copy. Got: #{reason}"

      {status, 0} = git.(["status", "--porcelain"])

      assert status == "",
             "a conflict that is aborted should leave nothing behind. Got: #{inspect(status)}"

      {head, 0} = git.(["rev-parse", "HEAD"])
      {main_head, 0} = git.(["rev-parse", "main"])
      assert String.trim(head) == String.trim(main_head), "HEAD moved despite the abort"
    end

  end

  describe "divergence git can reconcile without a conflict" do
    # 3168's own premise: two branches that diverged (main and the story
    # branch each have a commit the other lacks) but whose changes do not
    # touch the same lines merge without a git-level conflict at all, even
    # though the result may not build (a *semantic* break, caught afterward
    # by the gate that recompiles the target — not this function's job).
    # Aborting is for an actual conflict; divergence on its own must still
    # merge.
    test "still merges, rather than being refused for the divergence alone" do
      {:ok, root} = Briefly.create(directory: true)
      git = fn args -> System.cmd("git", args, cd: root, stderr_to_stdout: true) end

      {_, 0} = git.(["init", "--initial-branch=main"])
      {_, 0} = git.(["config", "user.email", "t@example.com"])
      {_, 0} = git.(["config", "user.name", "T"])

      File.write!(Path.join(root, "f.txt"), "base\n")
      {_, 0} = git.(["add", "."])
      {_, 0} = git.(["commit", "-m", "base"])

      {_, 0} = git.(["checkout", "-b", "side"])
      File.write!(Path.join(root, "g.txt"), "the story's work\n")
      {_, 0} = git.(["add", "g.txt"])
      {_, 0} = git.(["commit", "-m", "side's work, an unrelated file"])

      {_, 0} = git.(["checkout", "main"])
      File.write!(Path.join(root, "f.txt"), "main moved on\n")
      {_, 0} = git.(["commit", "-am", "main moved on, a different file"])

      env = Environment.new(:local, root)

      assert {:ok, %{output: output}} = Steps.merge(env, root, "side")
      assert output =~ "Merge made"
    end
  end
end
