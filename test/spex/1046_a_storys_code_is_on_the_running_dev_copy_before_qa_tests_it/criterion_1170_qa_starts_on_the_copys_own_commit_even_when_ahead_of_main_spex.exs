defmodule CodeMySpecSpex.Story1046.Criterion1170Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1170 — QA starts once the copy's own app serves the copy's
  commit, and not against main's app or the preview.

  Rule, revised 2026-09-28 (story 1003, Three Amigos, phase 2 of story 1108):
  QA no longer waits on a story's code reaching *main* at all — it waits on
  the story's own working copy having clean specs, no accepted issues and no
  analyzer problems. Story 1108 gave every copy its own app; promotion now
  follows QA (`code_on_running_copy` moved to depend on `qa_complete`, not
  the other way round), so the checkout QA tests is the agent's own,
  unpromoted worktree — not the checkout the application runs from.

  Originally this criterion asserted the opposite: QA was refused while a
  checkout was ahead of main, because it was main's app QA tested. That
  premise is what caused the failure this criterion used to guard against
  (Broken Oaths 2026-09-09, nine stories QA'd against code that had never
  reached the checkout being tested) — the fix now is that QA tests the
  agent's own checkout directly, so "ahead of main" no longer describes a
  copy QA hasn't seen; it describes exactly the copy QA is about to test.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The joins go through a real channel, which runs in a process of its own.
  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "QA is offered a story on its own copy even while that copy is ahead of main",
       criterion: 1170 do
    scenario "the agent has committed work that main does not have" do
      given_ "a story with clean specs, no issues and no problems, ready for QA on a checkout with unpromoted commits",
             context do
        context = a_promotable_project(context)
        context = CodeMySpecSpex.FullSatisfactionFixtures.apply_up_to_analysis(context)

        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_the_copy"))
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-am", "the story's work"])

        context = CodeMySpecSpex.FullSatisfactionFixtures.apply_qa_readiness_transition(context)

        # Never promoted — `code_on_running_copy` unsatisfied for this story,
        # on purpose. Under the old order that alone refused QA. Under the
        # new one it has to make no difference: promotion is downstream of
        # QA now, not upstream of it.
        {:ok, context}
      end

      when_ "the QA agent asks for its next work", context do
        {:ok, ask_for_next_work(context)}
      end

      then_ "it is handed the story, on this checkout, unpromoted", context do
        text = response_text(context.response)

        assert text =~ "QaStory",
               "QA should run on the agent's own checkout regardless of whether " <>
                 "that checkout has been promoted — promotion is what follows a " <>
                 "QA pass now, not what precedes it. Got: #{text}"

        {:ok, context}
      end

      then_ "starting the task addresses the copy's own app, not main's", context do
        prompt = start_qa_task(context)

        assert prompt =~ "this working copy's own instance",
               "the task should point QA at the checkout carrying the story's own " <>
                 "commit, not main's app — testing main here would test code that " <>
                 "never left the coding agent's worktree, the exact failure this " <>
                 "criterion exists to prevent. Got: #{prompt}"

        refute prompt =~ "#{@endpoint}.url()",
               "the prompt fell back to main's address instead of resolving this " <>
                 "checkout's own app. Got: #{prompt}"

        {:ok, context}
      end
    end
  end

  defp ask_for_next_work(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
    {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
    Map.put(context, :response, response)
  end

  # Through `start_task`, the surface an agent actually calls, so the
  # assertion below observes what `QaStory.command/2` really renders rather
  # than asserting against the task module directly.
  #
  # `own_copy_app_url_line/1` dispatches `ensure_app_running` live, over the
  # same channel the agent's checkout joined with — a real `GenServer.call`
  # with a real timeout, not a cached column read. Started in a `Task`
  # because it blocks on the reply this test itself has to answer, the same
  # push-and-reply shape `criterion_1183`'s `answer_restart_app/2` uses for
  # `restart_app`.
  defp start_qa_task(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

    task =
      Task.async(fn ->
        StartTask.execute(
          %{
            requirement_name: "qa_complete",
            entity_type: "story",
            entity_id: to_string(context.story.id),
            session_id: "spex-1170-#{System.unique_integer([:positive])}"
          },
          frame
        )
      end)

    assert_push "ensure_app_running", %{"ref" => ref}, 5_000

    reply_ref =
      Phoenix.ChannelTest.push(context.agent_socket, "ensure_app_running_result", %{
        "ref" => ref,
        "status" => "ok",
        "app_status" => "serving",
        "app_url" => "http://127.0.0.1:4100",
        "app_commit" => "cafef00d"
      })

    receive do
      %Phoenix.Socket.Reply{ref: ^reply_ref, status: :ok} -> :ok
    after
      1_000 -> flunk("ensure_app_running_result was never acknowledged")
    end

    {:reply, response, _frame} = Task.await(task, 5_000)
    response_text(response)
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
    {agent, agent_socket} = join_working_copy_socket(context, agent_root, "the coding agent's copy")

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
    |> Map.put(:agent_socket, agent_socket)
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
