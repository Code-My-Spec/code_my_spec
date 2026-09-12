defmodule CodeMySpecSpex.Story1046.Criterion3171Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 3171 — A conflict is aborted, not left on the shared checkout.

  Rule: a merge conflict is aborted immediately, and the agent is sent to
  resolve it in the copy it is promoting from.

  Superseded twice over now.

  First (bed1d974): a conflict used to stay in the running checkout,
  reasoning that the agent who wrote one side is the only party holding the
  answer and a clean tree after a refusal has nothing to act on. Measured
  cost of that: a worktree six commits behind main spent 2.5 hours
  converging a spec main had already retired, then wedged the shared dev
  checkout — the one machine QA runs from, with no test suite and no way to
  resolve in place — from 00:28 to 10:40 merging it in unattended. The
  identical branch, merged main-first in the worktree instead, conflicted
  immediately and was resolved in two minutes: the same conflict, but with
  context and a test suite, because it happened somewhere a person could
  see it. That gave the running checkout an abort-on-conflict merge that
  named the conflicting file.

  Second (54aa534c, phase two): `Runner.merge/4` is `--ff-only` now, and
  ff-only never inspects file content — it only checks ancestry, before
  touching a single byte. Any divergence, conflicting or not, refuses at
  that check, instantly, with nothing to abort because nothing was ever
  attempted. So this scenario — a real content conflict — is caught the
  same way a same-file-different-lines divergence is, or a completely
  unrelated-files divergence is: refused for being behind main, not
  merged-then-aborted-and-named. The file name is gone from the message on
  purpose; there is no merge attempt left to have inspected it.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Promotion.Tools.PromoteSync
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The joins go through a real channel, which runs in a process of its own.
  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A conflict is refused before it is attempted, and the agent is sent to resolve it locally" do
    scenario "main and the story branch changed the same line" do
      given_ "a story branch that changed a line", context do
        context = a_promotable_project(context)

        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_the_copy"))
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-am", "the story's work"])

        {:ok, context}
      end

      given_ "main has since changed the same line", context do
        write(context.running_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_main"))

        {_, 0} =
          git(context, context.running_root, ["commit", "-q", "-am", "somebody else's work"])

        {:ok, context}
      end

      given_ "both copies' analyzers are current", context do
        {:ok, analyzers_are_current(context)}
      end

      when_ "the agent promotes", context do
        {:ok, Map.put(context, :response, promote(context))}
      end

      then_ "the promotion does not complete", context do
        assert context.response.isError,
               "a conflicted merge was reported as a finished promotion"

        {:ok, context}
      end

      then_ "the agent is told it is behind main, not which file conflicts", context do
        text = response_text(context.response)

        assert text =~ "behind main",
               "ff-only refuses on ancestry alone and never inspected the tree, " <>
                 "so the refusal has to name what is actually true rather than " <>
                 "imply a conflict was found. Got: #{text}"

        {:ok, context}
      end

      then_ "the agent is told to resolve it in its own copy, not the running one", context do
        assert response_text(context.response) =~ "git merge --ff-only main",
               "the agent was refused without being told the remedy is its own to run"

        {:ok, context}
      end

      then_ "the running checkout is left exactly as it was", context do
        {out, 0} = git(context, context.running_root, ["status", "--porcelain"])

        assert out == "",
               "an aborted conflict is supposed to leave nothing behind. Got: #{inspect(out)}"

        {:ok, context}
      end
    end
  end

  # Both copies' analyzers are current.
  #
  # A real precondition, not test scaffolding: the gate will not call a copy
  # clean on an unswept tree, which is criterion 3166. Any scenario about what
  # happens *after* the gate opens has to say that it opens, and this is how a
  # copy says its analyzers have run. 3166 deliberately omits it.
  defp analyzers_are_current(context) do
    CodeMySpecSpex.Fixtures.fresh_analysis_runs(context.scope)

    CodeMySpecSpex.Fixtures.fresh_analysis_runs(%{
      context.scope
      | active_working_copy_id: context.running.working_copy_id
    })

    context
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

  # Through `promote_sync` rather than `promote`.
  #
  # Both doors run the same `Promotion.promote/1`; they differ only in delivery.
  # `promote` is the agent's — it returns at once and messages the outcome back,
  # which is right for minutes of analyzer sweep and wrong for a spec, because
  # there is no outcome in the reply to assert on. `promote_sync` is the door
  # for a caller that has nowhere to be messaged, and it answers.
  defp promote(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
    {:reply, response, _frame} = PromoteSync.execute(%{}, frame)
    response
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

  defp read(root, path) do
    {:ok, content} = Environments.read_file(disk(root), path)
    content
  end

  defp exists?(root, path), do: Environments.file_exists?(disk(root), path)
end
