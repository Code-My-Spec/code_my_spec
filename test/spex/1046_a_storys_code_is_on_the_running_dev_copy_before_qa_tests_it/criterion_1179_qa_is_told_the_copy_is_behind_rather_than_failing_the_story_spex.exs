defmodule CodeMySpecSpex.Story1046.Criterion3172Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 3172 — QA is told the copy is behind rather than failing the story.

  Rule, revised 2026-09-28 (story 1003, Three Amigos, phase 2 of story 1108):
  the belt to 3162's suspenders, re-pointed at the new order. QA now tests
  the agent's own checkout directly, so a story ready for QA is never routed
  to a promotion first — promotion is what follows a QA pass, not what
  precedes it. Asserting both directions in one spec: QA is offered, and
  promotion specifically is not offered instead.

  Originally this asserted the opposite direction: an unpromoted checkout was
  routed to `PromoteWork`, not `QaStory`, so QA would never discover a missing
  feature by testing for it — the nine false defects of 2026-09-09, where QA
  was right about what it saw and wrong about what it meant. That protection
  is now structural rather than an ordering trick: QA tests the checkout the
  work actually landed on, so there is no other checkout for it to be
  surprised by.

  The original criterion's fuller framing — QA told explicitly when *its own
  copy's app* has not yet caught up to the commit it is meant to test, as
  opposed to promotion status — depends on comparing a submitted QA attempt's
  recorded commit against the story's current one, which this revision does
  not yet implement (deferred: recording the commit `AppTransport.ensure_app_running/2`
  returns at QA kickoff onto the attempt, and checking it in `Qa.complete_check/2,3`).
  `own_copy_app_url_line/1` in `qa_story.ex` already tells the agent plainly
  when its own copy's app is down or unreachable rather than silently pointing
  at a stale address — see that module for what is covered today.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The joins go through a real channel, which runs in a process of its own.
  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A story ready for QA on its own checkout is offered testing, not a promotion",
       criterion: 1179 do
    scenario "the checkout has work main has not seen" do
      given_ "a story with clean specs, no issues and no problems, on a checkout with unpromoted commits",
             context do
        context = a_promotable_project(context)
        context = CodeMySpecSpex.FullSatisfactionFixtures.apply_up_to_analysis(context)

        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_the_copy"))
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-am", "the story's work"])

        context = CodeMySpecSpex.FullSatisfactionFixtures.apply_qa_readiness_transition(context)

        {:ok, context}
      end

      when_ "the QA agent asks what to do about that story", context do
        {:ok, ask_for_next_work(context)}
      end

      then_ "it is routed to testing, not to a promotion", context do
        text = response_text(context.response)

        assert text =~ "QaStory",
               "the story was not routed to QA. Got: #{text}"

        refute text =~ "PromoteWork",
               "promotion should not be offered ahead of QA any more — a " <>
                 "story reaches a promotion only after it passes"

        {:ok, context}
      end
    end
  end

  defp ask_for_next_work(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
    {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
    Map.put(context, :response, response)
  end

  # Two checkouts of one repository, which is what a promotion actually meets.
  #
  # The application runs from `main` in one checkout; the coding agent works in
  # a worktree of it, on the story's branch. They share an object store, so the
  # running checkout merges the agent's branch by name with no remote involved
  # — and that is the arrangement on John's own machine, where eight worktrees
  # hang off one checkout.
  #
  # Arranged as two real checkouts rather than one, because a promotion that
  # merges into the tree it is promoting *from* is not a promotion, and a spec
  # built on one repository cannot tell the two apart.
  defp a_promotable_project(context) do
    running_root = CodeMySpec.TempFile.dir("spex-1046-running")
    {_, 0} = Environments.cmd(context.environment, "mkdir", ["-p", running_root])

    {_, 0} = git(context, running_root, ["init", "--initial-branch", "main"])
    {_, 0} = git(context, running_root, ["config", "user.email", "spex@example.com"])
    {_, 0} = git(context, running_root, ["config", "user.name", "Spex"])

    write(running_root, "lib/broken_oaths/diplomacy/war.ex", war(":base"))

    # The project's own restart recipe, which is the seam a promotion uses
    # instead of knowing how to bring a Phoenix app up.
    #
    # It compiles before it records, because that is what a real one does — the
    # recipe in this repo runs `mix loadpaths`, `deps.compile` and `ecto.migrate`
    # before it launches anything, and a tree that will not build takes the
    # restart down with it. That is what makes criterion 3168 reachable without
    # an analyzer: a merge that breaks the target is caught here, by the
    # application failing to come back up.
    #
    # `--warnings-as-errors` because a call to a function another module no
    # longer exports is a warning in Elixir, and `just check` in this repo is
    # `mix compile --warnings-as-errors` for exactly that reason.
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

    {out, 0} =
      git(context, running_root, ["worktree", "add", "-b", "story/war", agent_root, "main"])

    _ = out

    running = join_working_copy(context, running_root, "the checkout the dev app runs in")
    agent = join_working_copy(context, agent_root, "the coding agent's copy")

    # The running checkout joined first and so holds the designation: the
    # project's first checkout to report a root becomes its main copy
    # (`working_copies.ex:444`). Asserted, because a promotion aimed at a copy
    # that is not main is a promotion to nowhere and every scenario below would
    # pass for the wrong reason.
    {:ok, _view, html} =
      live(context.conn, "/app/projects/#{context.project.id}/working-copies")

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

  # An explicit `:cd` wins over the environment's own cwd
  # (`environments/local.ex:217`), which is what lets one environment drive two
  # checkouts.
  defp git(context, dir, args),
    do: Environments.cmd(context.environment, "git", args, cd: dir, stderr_to_stdout: true)

  defp war(body) do
    "defmodule BrokenOaths.Diplomacy.War do\n  def declare, do: #{body}\nend\n"
  end

  # A local environment over the OS temp filesystem, which is where git looks.
  #
  # The suite's own environment fakes the *domain* filesystem while delegating
  # execution to the real one (`environments_behaviour.ex:128`), so a file
  # written through it is invisible to `git` — which is why these checkouts get
  # an environment of their own rather than raw `File`, and why the spex denial
  # on `File` is right rather than something to disable.
  defp disk(root), do: Environment.new(:local, root)

  defp write(root, path, content), do: :ok = Environments.write_file(disk(root), path, content)
end
