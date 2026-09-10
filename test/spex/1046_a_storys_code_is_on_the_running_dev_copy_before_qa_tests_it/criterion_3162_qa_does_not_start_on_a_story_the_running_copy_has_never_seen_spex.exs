defmodule CodeMySpecSpex.Story1046.Criterion3162Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 3162 — QA does not start on a story the running copy has never seen.

  Rule: A story's code must be present on the running dev copy before QA work
  on that story begins.

  The failure this exists to stop, measured on Broken Oaths 2026-09-09: nine
  stories were handed to QA whose implementation had never left the coding
  agent's worktree. QA failed all nine — correctly, because the code it tested
  was not the code that had been written. Nine defects that were not defects.

  Asked of git rather than of files. "Has this checkout's work reached main"
  is a question about commits, and answering it from file rows depends on scans
  landing, on story-to-component linkage, and on roles being classified right —
  three ways to answer yes for a checkout that is behind.
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

  spex "QA is not offered a story while the checkout is ahead of main" do
    scenario "the agent has committed work that main does not have" do
      given_ "a story ready for QA on a checkout with unpromoted commits", context do
        context = a_promotable_project(context)
        context = CodeMySpecSpex.FullSatisfactionFixtures.apply_without_qa_story(context)

        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_the_copy"))
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-am", "the story's work"])

        {:ok, report_git_state(context, context.agent_root, context.agent.working_copy_id)}
      end

      when_ "the QA agent asks for its next work", context do
        {:ok, ask_for_next_work(context)}
      end

      then_ "it is not handed the story", context do
        text = response_text(context.response)

        refute text =~ "QaStory",
               "QA was handed a story whose code has never reached the copy it " <>
                 "tests. Got: #{text}"

        {:ok, context}
      end
    end
  end

  # Measure this checkout's git state and record it the way its harness would.
  #
  # The three numbers the gate reads: commits here that main lacks, commits on
  # main that this lacks, and whether the tree is dirty. Taken from a real
  # repository with real commits — only the delivery over the channel is
  # short-circuited, because a spec has no harness.
  defp report_git_state(context, root, copy_id) do
    {ahead, 0} = git(context, root, ["rev-list", "--count", "main..HEAD"])
    {behind, 0} = git(context, root, ["rev-list", "--count", "HEAD..main"])
    {status, 0} = git(context, root, ["status", "--porcelain", "--untracked-files=no"])

    CodeMySpecSpex.Fixtures.record_git_state(copy_id, %{
      ahead: String.to_integer(String.trim(ahead)),
      behind: String.to_integer(String.trim(behind)),
      dirty: String.trim(status) != ""
    })

    context
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
