defmodule CodeMySpecSpex.PromotionHelpers do
  @moduledoc """
  The two checkouts a promotion actually meets, and the door it is driven through.

  Here for the reason `WorkingCopyHelpers` gives for itself: "a helper copied
  eight times is a parsing bug fixed seven times and missed once". Story 1046
  went past eight some time ago — `a_promotable_project/1` is currently written
  out in fourteen of its criteria, identically, and the five criteria added on
  2026-09-12 would have made nineteen.

  The existing fourteen are deliberately left alone rather than migrated in the
  same change that adds new ones. Moving them is a mechanical edit across files
  another session was rewriting the same evening, and a spec suite is the worst
  place to find out that two people edited the same fixture from different
  directions. They should move; not in the commit that introduces this.

  ## Why two real checkouts

  A promotion that merges into the tree it is promoting *from* is not a
  promotion, and a fixture built on one repository cannot tell those apart. So
  this makes a checkout with `main` and a worktree of it on a story branch —
  which is also the arrangement on John's own machine, where nine worktrees hang
  off one checkout and every one of tonight's promotion defects lived in the gap
  between them.
  """

  import ExUnit.Assertions
  # `live/2` expands to `get/2`, which lives in ConnTest rather than LiveViewTest.
  import Phoenix.ConnTest, except: [delete: 2]
  import Phoenix.LiveViewTest
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Promotion.Tools.PromoteSync

  @endpoint CodeMySpecWeb.Endpoint

  @doc """
  A running checkout on `main` and an agent's worktree on `story/war`.

  Returns the context with `:running_root`, `:agent_root`, `:running`, `:agent`,
  and `:scope` repointed at the agent's copy — which is the scope a promoting
  agent actually holds.
  """
  def a_promotable_project(context) do
    running_root = CodeMySpec.TempFile.dir("spex-1046-running")
    {_, 0} = Environments.cmd(context.environment, "mkdir", ["-p", running_root])

    {_, 0} = git(context, running_root, ["init", "--initial-branch", "main"])
    {_, 0} = git(context, running_root, ["config", "user.email", "spex@example.com"])
    {_, 0} = git(context, running_root, ["config", "user.name", "Spex"])

    write(running_root, "lib/broken_oaths/diplomacy/war.ex", war(":base"))

    # The project's own restart recipe, which is the seam a promotion uses
    # instead of knowing how to bring a Phoenix app up. It compiles before it
    # records, because a real one does — so a merge that breaks the target is
    # caught by the application failing to come back rather than by an analyzer.
    write(running_root, "justfile", """
    restart:
        @elixirc -o {{justfile_directory()}}/_spex_build \\
            {{justfile_directory()}}/lib/broken_oaths/diplomacy/*.ex
        @date > {{justfile_directory()}}/.restarted
    """)

    {_, 0} = git(context, running_root, ["add", "-A"])
    {_, 0} = git(context, running_root, ["commit", "-q", "-m", "base"])

    # `worktree add` requires the path not to exist yet.
    agent_root = CodeMySpec.TempFile.dir("spex-1046-agent")
    {_, 0} = Environments.cmd(context.environment, "rm", ["-rf", agent_root])

    {_out, 0} =
      git(context, running_root, ["worktree", "add", "-b", "story/war", agent_root, "main"])

    running = join_working_copy(context, running_root, "the checkout the dev app runs in")
    agent = join_working_copy(context, agent_root, "the coding agent's copy")

    # The running checkout joined first and so holds the designation. Asserted,
    # because a promotion aimed at a copy that is not main is a promotion to
    # nowhere, and every scenario built on this would pass for the wrong reason.
    {:ok, _view, html} = live(context.conn, "/app/projects/#{context.project.id}/working-copies")

    refute html =~
             ~s(phx-value-id="#{running.working_copy_id}" data-test="designate-main-copy"),
           "the premise failed: the running checkout is not this project's main copy"

    context
    |> Map.put(:running_root, running_root)
    |> Map.put(:agent_root, agent_root)
    |> Map.put(:running, running)
    |> Map.put(:agent, agent)
    |> Map.put(:scope, %{context.scope | active_working_copy_id: agent.working_copy_id})
  end

  @doc """
  Both copies' analyzers current.

  A real precondition rather than scaffolding: the gate will not call a copy
  clean at a commit no run answers for, so any scenario about what happens
  *after* the gate opens has to say that it opens.
  """
  def analyzers_are_current(context) do
    CodeMySpecSpex.Fixtures.fresh_analysis_runs(context.scope)

    CodeMySpecSpex.Fixtures.fresh_analysis_runs(%{
      context.scope
      | active_working_copy_id: context.running.working_copy_id
    })

    context
  end

  @doc """
  Promote, through `promote_sync`.

  Both doors run the same `Promotion.promote/1` and differ only in delivery.
  `promote` is the agent's — it answers at once and messages the outcome back,
  which leaves a spec nothing in the reply to assert on. `promote_sync` is the
  door for a caller with nowhere to be messaged, and it answers.
  """
  def promote(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
    {:reply, response, _frame} = PromoteSync.execute(%{}, frame)
    response
  end

  @doc "An explicit `:cd` wins over the environment's own cwd, which is what lets one environment drive two checkouts."
  def git(context, dir, args),
    do: Environments.cmd(context.environment, "git", args, cd: dir, stderr_to_stdout: true)

  @doc "The commit a checkout is on."
  def head_of(context, root) do
    {out, 0} = git(context, root, ["rev-parse", "HEAD"])
    String.trim(out)
  end

  @doc "A module whose body the scenario controls, so a merge has something to carry."
  def war(body) do
    "defmodule BrokenOaths.Diplomacy.War do\n  def declare, do: #{body}\nend\n"
  end

  @doc "A second module, for giving main a commit the story branch does not have."
  def treaty do
    "defmodule BrokenOaths.Diplomacy.Treaty do\n  def sign, do: :signed\nend\n"
  end

  def disk(root), do: Environment.new(:local, root)

  def write(root, path, content), do: :ok = Environments.write_file(disk(root), path, content)

  def read(root, path) do
    {:ok, contents} = Environments.read_file(disk(root), path)
    contents
  end

  def exists?(root, path), do: Environments.file_exists?(disk(root), path)
end
