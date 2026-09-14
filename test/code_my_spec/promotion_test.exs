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
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Promotion
  alias CodeMySpec.Promotion.{Runner, Steps}
  alias CodeMySpec.WorkingCopies

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

  describe "a restart whose acknowledgement never comes back" do
    # Promotion restarts the application on the running copy; the running copy
    # is :4000; every harness channel is served by :4000. So the happy path ends
    # with the server dropping the connection the reply was coming back on, and
    # the caller is told it could not reach the machine — for a promotion whose
    # merge already landed two steps earlier.
    #
    # What the wrong reading costs: an agent told its promotion failed promotes
    # again, and each retry restarts the shared dev server every other working
    # copy on the box is using. Measured at three in one session.

    test "the timeout shape a successful restart produces is recognised" do
      assert Promotion.restart_acknowledgement_lost?(%{
               reason:
                 "could not reach the machine holding this checkout: " <>
                   "{:harness_timeout, %{op: \"promotion_restart\", elapsed_ms: 2377}}"
             })
    end

    test "so is the HTTP door's version, which wears a different error" do
      assert Promotion.restart_acknowledgement_lost?(%{
               reason: "could not promote: :not_connected"
             })

      assert Promotion.restart_acknowledgement_lost?(%{reason: "{:shutdown, :draining}"})
    end

    test "a genuine refusal is not mistaken for one" do
      refute Promotion.restart_acknowledgement_lost?(%{
               reason: "this copy has uncommitted work. Commit it, then promote."
             })

      refute Promotion.restart_acknowledgement_lost?(%{
               reason: "merging light-harness into the running copy conflicts in foo.exs"
             })

      refute Promotion.restart_acknowledgement_lost?(:whatever)
    end
  end

  describe "a branch that has diverged from main, conflicting or not" do
    # 54aa534c, phase two: the precondition and the merge collapsed into one
    # command. `branch` must already contain everything `root`'s HEAD has, or
    # `git merge --ff-only` refuses before touching the tree at all — so a
    # *content* conflict is no longer reachable here: divergence refuses
    # first, whether or not the divergent commits would have conflicted.
    #
    # Both shapes are covered on purpose. `bed1d974` measured the cost of a
    # real conflict left in place (a worktree six commits behind main wedged
    # the shared dev checkout for ten hours); 3168 established that mere
    # divergence with no conflicting lines used to be allowed through. Both
    # premises are superseded by the same change — divergence itself, not
    # just a conflict, is what gets refused now.
    setup do
      {:ok, root} = Briefly.create(directory: true)
      git = fn args -> System.cmd("git", args, cd: root, stderr_to_stdout: true) end

      {_, 0} = git.(["init", "--initial-branch=main"])
      {_, 0} = git.(["config", "user.email", "t@example.com"])
      {_, 0} = git.(["config", "user.name", "T"])

      File.write!(Path.join(root, "f.txt"), "base\n")
      {_, 0} = git.(["add", "."])
      {_, 0} = git.(["commit", "-m", "base"])

      %{root: root, git: git, env: Environment.new(:local, root)}
    end

    test "a content conflict is refused before it is ever attempted, and nothing moves",
         %{root: root, git: git, env: env} do
      {_, 0} = git.(["checkout", "-b", "side"])
      File.write!(Path.join(root, "f.txt"), "side\n")
      {_, 0} = git.(["commit", "-am", "side"])

      {_, 0} = git.(["checkout", "main"])
      File.write!(Path.join(root, "f.txt"), "main\n")
      {_, 0} = git.(["commit", "-am", "main"])

      assert {:error, %{reason: reason}} = Steps.merge(env, root, "side")

      assert reason =~ "behind main",
             "the refusal has to name what is actually true — the branch is " <>
               "missing commits, not that a merge was attempted and failed. Got: #{reason}"

      assert reason =~ "not a mistake",
             "divergence from another promotion landing mid-work is routine on a " <>
               "shared checkout, and the wording has to say so rather than read " <>
               "like an error the agent caused. Got: #{reason}"

      assert reason =~ "git merge --ff-only main",
             "the remedy is the agent's to run, in its own copy. Got: #{reason}"

      {status, 0} = git.(["status", "--porcelain"])

      assert status == "",
             "nothing should be attempted, let alone left behind. Got: #{inspect(status)}"

      {head, 0} = git.(["rev-parse", "HEAD"])
      {main_head, 0} = git.(["rev-parse", "main"])
      assert String.trim(head) == String.trim(main_head), "HEAD moved despite the refusal"
    end

    test "divergence with no conflicting lines is refused the same way, not merged", %{
      root: root,
      git: git,
      env: env
    } do
      {_, 0} = git.(["checkout", "-b", "side"])
      File.write!(Path.join(root, "g.txt"), "the story's work\n")
      {_, 0} = git.(["add", "g.txt"])
      {_, 0} = git.(["commit", "-m", "side's work, an unrelated file"])

      {_, 0} = git.(["checkout", "main"])
      File.write!(Path.join(root, "f.txt"), "main moved on\n")
      {_, 0} = git.(["commit", "-am", "main moved on, a different file"])

      assert {:error, %{reason: reason}} = Steps.merge(env, root, "side"),
             "a three-way merge here used to succeed because the changes did not " <>
               "touch the same lines — the branch is still missing a commit main " <>
               "has, and that alone is refused now, conflict or not"

      assert reason =~ "behind main"
    end

    test "a branch that already has everything main has still merges", %{
      root: root,
      git: git,
      env: env
    } do
      {_, 0} = git.(["checkout", "-b", "side"])
      File.write!(Path.join(root, "g.txt"), "the story's work\n")
      {_, 0} = git.(["add", "g.txt"])
      {_, 0} = git.(["commit", "-m", "side's work"])

      assert {:ok, %{output: output}} = Steps.merge(env, root, "side")
      assert output =~ "Fast-forward" or output =~ "up to date"
    end
  end

  describe "a promotion originates a version" do
    setup do
      {:ok, root} = Briefly.create(directory: true)
      git = fn args -> System.cmd("git", args, cd: root, stderr_to_stdout: true) end

      {_, 0} = git.(["init", "--initial-branch=main"])
      {_, 0} = git.(["config", "user.email", "t@example.com"])
      {_, 0} = git.(["config", "user.name", "T"])

      %{root: root, git: git, env: Environment.new(:local, root)}
    end

    test "bumps mix.exs's patch version, tags the commit, and reports it",
         %{root: root, git: git, env: env} do
      File.write!(Path.join(root, "mix.exs"), ~s([\n  version: "1.2.3",\n]\n))
      {_, 0} = git.(["add", "."])
      {_, 0} = git.(["commit", "-m", "base"])

      {_, 0} = git.(["checkout", "-b", "side"])
      File.write!(Path.join(root, "g.txt"), "the story's work\n")
      {_, 0} = git.(["add", "g.txt"])
      {_, 0} = git.(["commit", "-m", "side's work"])

      assert {:ok, %{version: "1.2.4"}} = Steps.merge(env, root, "side")

      assert File.read!(Path.join(root, "mix.exs")) =~ ~s(version: "1.2.4")

      {tags, 0} = git.(["tag", "--list"])
      assert tags =~ "v1.2.4"

      {status, 0} = git.(["status", "--porcelain"])
      assert status == "", "the version bump has to land as a commit, not sit uncommitted"
    end

    test "a checkout with no mix.exs merges anyway and originates no version",
         %{root: root, git: git, env: env} do
      File.write!(Path.join(root, "f.txt"), "base\n")
      {_, 0} = git.(["add", "."])
      {_, 0} = git.(["commit", "-m", "base"])

      {_, 0} = git.(["checkout", "-b", "side"])
      File.write!(Path.join(root, "g.txt"), "the story's work\n")
      {_, 0} = git.(["add", "g.txt"])
      {_, 0} = git.(["commit", "-m", "side's work"])

      assert {:ok, %{version: nil}} = Steps.merge(env, root, "side"),
             "a merge does not fail because the checkout it landed on has " <>
               "nothing to bump — that is the merge succeeding without also " <>
               "minting a version, not the merge failing"
    end
  end

  describe "code_on_running_copy reads the story's stamp, not the checkout's live state" do
    setup do
      scope = full_scope_fixture()
      device = device_fixture(scope)

      {:ok, running} =
        WorkingCopies.issue(scope, nil,
          root: "/tmp/running-#{System.unique_integer([:positive])}",
          label: "running",
          device: device
        )

      {:ok, _} = WorkingCopies.designate_main(scope, running.id)

      {:ok, agent} =
        WorkingCopies.issue(scope, nil,
          root: "/tmp/agent-#{System.unique_integer([:positive])}",
          label: "agent",
          device: device
        )

      scope = %{scope | active_working_copy_id: agent.id}
      story = story_fixture(scope, %{working_copy_id: agent.id})

      %{scope: scope, agent: agent, story: story}
    end

    test "a story stamped with a version is satisfied even while its checkout is ahead and dirty",
         %{scope: scope, agent: agent, story: story} do
      {:ok, _} =
        WorkingCopies.record_git_state(agent, %{
          ahead: 3,
          behind: 0,
          dirty: true
        })

      story = %{story | promoted_version: "2.0.11"}

      assert {true, %{status: status}} = Promotion.running_copy_check(scope, story)
      assert status =~ "2.0.11"
    end

    test "a story never promoted is refused even while its checkout looks in sync",
         %{scope: scope, agent: agent, story: story} do
      {:ok, _} =
        WorkingCopies.record_git_state(agent, %{
          ahead: 0,
          behind: 0,
          dirty: false
        })

      assert {false, %{reason: reason, promoted: false}} =
               Promotion.running_copy_check(scope, story)

      assert reason =~ "has not been promoted yet",
             "an in-sync checkout is not the same claim as a promoted story — " <>
               "the checkout can look clean for a reason that has nothing to do " <>
               "with this story ever having promoted. Got: #{reason}"
    end

    test "reusing the same checkout for a second story does not un-satisfy the first",
         %{scope: scope, agent: agent, story: story} do
      story = %{story | promoted_version: "2.0.11"}

      # The exact failure this stamp exists to stop: new work for a different
      # story lands on the same checkout after story's own promotion, dirtying
      # it and moving it ahead of main again.
      {:ok, _} =
        WorkingCopies.record_git_state(agent, %{
          ahead: 1,
          behind: 0,
          dirty: true
        })

      assert {true, _} = Promotion.running_copy_check(scope, story)
    end
  end

  describe "a submodule dirtied by an in-progress QA session" do
    # A QA agent writes into `.code_my_spec` continuously for the one-to-two
    # hours it works — a brief drafted, `prompt.md` regenerated on every task
    # it opens — none of which is code this checkout's own merge would carry.
    # `precheck/2` used to refuse the whole promotion for the length of a QA
    # session over exactly that (c97bb142).
    #
    # A modified TRACKED file inside the submodule, not a fresh untracked one
    # — confirmed empirically that only the former makes `git status` report
    # the submodule as dirty in the superproject at all, and "regenerated on
    # every task" is a rewrite of a file the submodule already tracks.
    test "does not refuse a checkout whose only dirt is inside the submodule" do
      {:ok, submodule_root} = Briefly.create(directory: true)
      sub_git = fn args -> System.cmd("git", args, cd: submodule_root, stderr_to_stdout: true) end

      {_, 0} = sub_git.(["init", "-q", "--initial-branch=main"])
      {_, 0} = sub_git.(["config", "user.email", "t@example.com"])
      {_, 0} = sub_git.(["config", "user.name", "T"])
      File.write!(Path.join(submodule_root, "qa_brief.md"), "draft\n")
      {_, 0} = sub_git.(["add", "-A"])
      {_, 0} = sub_git.(["commit", "-q", "-m", "initial brief"])

      {:ok, root} = Briefly.create(directory: true)
      git = fn args -> System.cmd("git", args, cd: root, stderr_to_stdout: true) end

      {_, 0} = git.(["init", "-q", "--initial-branch=main"])
      {_, 0} = git.(["config", "user.email", "t@example.com"])
      {_, 0} = git.(["config", "user.name", "T"])
      File.write!(Path.join(root, "app.ex"), "defmodule App do\nend\n")
      {_, 0} = git.(["add", "-A"])
      {_, 0} = git.(["commit", "-q", "-m", "initial commit"])

      {_, 0} =
        git.([
          "-c",
          "protocol.file.allow=always",
          "submodule",
          "add",
          "-q",
          submodule_root,
          ".code_my_spec"
        ])

      {_, 0} = git.(["commit", "-q", "-m", "add submodule"])

      # The QA agent's own act: rewriting a file the submodule already tracks.
      File.write!(Path.join(root, ".code_my_spec/qa_brief.md"), "in progress\n")

      env = Environment.new(:local, root)

      assert {:ok, %{branch: "main"}} = Steps.precheck(env, root),
             "a submodule with a modified tracked file made this checkout read " <>
               "as dirty, refusing every promotion for the length of a QA session"
    end

    test "still refuses when the checkout itself has uncommitted work" do
      {:ok, root} = Briefly.create(directory: true)
      git = fn args -> System.cmd("git", args, cd: root, stderr_to_stdout: true) end

      {_, 0} = git.(["init", "-q", "--initial-branch=main"])
      {_, 0} = git.(["config", "user.email", "t@example.com"])
      {_, 0} = git.(["config", "user.name", "T"])
      File.write!(Path.join(root, "app.ex"), "defmodule App do\nend\n")
      {_, 0} = git.(["add", "-A"])
      {_, 0} = git.(["commit", "-q", "-m", "initial commit"])

      File.write!(Path.join(root, "app.ex"), "defmodule App do\n  def changed, do: true\nend\n")

      env = Environment.new(:local, root)

      assert {:error, %{reason: reason}} = Steps.precheck(env, root)

      assert reason =~ "uncommitted work",
             "ignoring submodule dirt must not also hide a real, uncommitted " <>
               "change to the checkout's own tracked files"
    end
  end
end
