defmodule CodeMySpecSpex.Story1046.Criterion1509Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1509 — Promoted work is not QA'd again on main.

  Rule (story 1003, Three Amigos, phase 2 of story 1108): `qa_complete` is a
  fact about the story, recorded once as a DB attempt
  (`CodeMySpec.Qa.QaAttempt`) keyed on `story_id` alone — not a fact about
  whichever working copy happens to be asking. `promote` merges the story's
  commit onto main and stamps `promoted_version`; neither step touches the
  QA attempt. A story that passed QA on its own copy stays passed once that
  work reaches main — main never has to re-earn what the copy already
  proved, because there is nothing on the attempt itself for landing the
  code to invalidate.

  This is also why "QA it again on main" is not a request the graph could
  even route: `get_next_requirement` only ever discovers work for the
  calling working copy's own active story
  (`WorkingCopies.set_active_story/2` refuses to name a story already tied
  to a different copy), so main is structurally never offered a story that
  belongs to another checkout. What this criterion actually guards is
  narrower and just as real: that the act of promotion itself does not
  reset or re-open `qa_complete` for the story it just landed.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.McpServers.Promotion.Tools.PromoteSync
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.Fixtures.StoryIssueBag
  alias CodeMySpecSpex.PromotionHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A promotion does not re-open the QA it followed", criterion: 1509 do
    scenario "the story stays qa_complete after its work lands on main" do
      given_ "a story that passed QA on its own copy and is ready to promote", context do
        context = a_promotable_project(context)
        context = CodeMySpecSpex.FullSatisfactionFixtures.apply_up_to_analysis(context)
        PromotionHelpers.materialize_source_fixture_files(context)

        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_the_copy"))
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-am", "the story's work"])

        context = CodeMySpecSpex.FullSatisfactionFixtures.apply_qa_readiness_transition(context)

        :ok =
          StoryIssueBag.certify(
            context.scope,
            context.story.id,
            PromotionHelpers.head_of(context, context.agent_root)
          )

        {:ok, _attempt} = Fixtures.passed_qa_attempt(context.scope, story_id: context.story.id)

        {:ok, context}
      end

      when_ "the story is promoted", context do
        context = analyzers_are_current(context)
        response = promote(context, context.story.number)
        text = response_text(response)

        assert text =~ "Restarted" or text =~ "serving",
               "promotion refused before deployment: #{text}"

        answer_restart_app_ok(context.running_socket)
        {:ok, Map.put(context, :promote_response, response)}
      end

      then_ "qa_complete is still satisfied — the promotion did not reset it", context do
        text = qa_complete_status(context)

        assert text =~ "[x] **qa_complete**",
               "promoting a story should not clear the QA pass that earned it — " <>
                 "promote reported: #{response_text(context.promote_response)}. " <>
                 "Got: #{text}"

        {:ok, context}
      end

      then_ "asking for this story's next work does not offer QaStory a second time",
            context do
        text = ask_for_next_work(context)

        refute text =~ "QaStory",
               "a story already QA'd and promoted should never be re-offered testing " <>
                 "just because it was promoted. Got: #{text}"

        {:ok, context}
      end
    end
  end

  defp ask_for_next_work(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

    response =
      ToolLibrary.run(
        "get_next_requirement",
        %{},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    response_text(response)
  end

  defp qa_complete_status(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

    response =
      ToolLibrary.run(
        "list_requirements",
        %{
          entity_type: "story",
          entity_id: to_string(context.story.number),
          requirement_name: "qa_complete"
        },
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    response_text(response)
  end

  defp analyzers_are_current(context) do
    Fixtures.fresh_analysis_runs(context.scope, ~w(compiler credo exunit spex), at_head: true)

    Fixtures.fresh_analysis_runs(
      %{context.scope | active_working_copy_id: context.running.working_copy_id},
      ~w(compiler credo exunit spex),
      at_head: true
    )

    context
  end

  defp promote(context, story_number) do
    # A distinct merged tree requires the gate responses this scenario supplies.
    PromotionHelpers.commit_work(
      context,
      context.running_root,
      "main-only.txt",
      "Independent main work\n"
    )

    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
    task = Task.async(fn -> PromoteSync.execute(%{story_number: story_number}, frame) end)

    with_task_cleanup(task, fn ->
      PromotionHelpers.the_gate_answers(context)
      {:reply, response, _frame} = Task.await(task, 30_000)
      response
    end)
  end

  # Standing in for the harness on the other end of `restart_app`, the way
  # criterion 1183's own `answer_restart_app/2` does. `Runner.restart/3`
  # dispatches through `AppTransport.restart_app/2` and never awaits it
  # (54aa534c, phase two) — leaving it unanswered would not fail this test,
  # it would leave a detached task blocked on this channel for the full
  # 10-minute `@restart_timeout`, risking an error log landing in the
  # middle of an unrelated later test.
  defp answer_restart_app_ok(socket) do
    assert_push("restart_app", %{"ref" => ref}, 5_000)

    reply_ref =
      Phoenix.ChannelTest.push(socket, "restart_app_result", %{
        "ref" => ref,
        "status" => "ok",
        "app_status" => "serving",
        "app_url" => "http://127.0.0.1:4100",
        "app_commit" => "cafef00d"
      })

    receive do
      %Phoenix.Socket.Reply{ref: ^reply_ref, status: :ok} -> :ok
    after
      1_000 -> flunk("restart_app_result was never acknowledged")
    end
  end

  # Two checkouts of one repository, which is what a promotion actually meets.
  # See criterion 1170's own copy of this helper for the full rationale.
  defp a_promotable_project(context) do
    PromotionHelpers.local_bootstrap_project(context)
    PromotionHelpers.stop_the_queue_on_exit(context.project.id)
    running_root = CodeMySpec.TempFile.dir("spex-1509-running")
    {_, 0} = ExecutionContexts.cmd(context.execution_context, "mkdir", ["-p", running_root])

    {_, 0} = git(context, running_root, ["init", "--initial-branch", "main"])
    {_, 0} = git(context, running_root, ["config", "user.email", "spex@example.com"])
    {_, 0} = git(context, running_root, ["config", "user.name", "Spex"])

    write(running_root, "lib/broken_oaths/diplomacy/war.ex", war(":base"))

    write(running_root, "justfile", """
    restart:
        @elixirc -o {{justfile_directory()}}/_spex_build \\
            {{justfile_directory()}}/lib/broken_oaths/diplomacy/*.ex
        @date > {{justfile_directory()}}/.restarted
    """)

    {_, 0} = git(context, running_root, ["add", "-A"])
    {_, 0} = git(context, running_root, ["commit", "-q", "-m", "base"])
    {_, 0} = git(context, running_root, ["tag", "-a", "v0.1.0", "-m", "v0.1.0"])

    agent_root = CodeMySpec.TempFile.dir("spex-1509-agent")
    {_, 0} = ExecutionContexts.cmd(context.execution_context, "rm", ["-rf", agent_root])

    {out, 0} =
      git(context, running_root, ["worktree", "add", "-b", "story/war", agent_root, "main"])

    _ = out

    {running, running_socket} =
      CodeMySpecSpex.PromotionHelpers.join_main_working_copy_socket(
        context,
        running_root,
        "the checkout the dev app runs in"
      )

    agent =
      CodeMySpecSpex.PromotionHelpers.join_local_working_copy(
        context,
        agent_root,
        "the coding agent's copy"
      )

    context = PromotionHelpers.a_gate_copy(context, running_root)

    {:ok, _view, html} =
      live(context.conn, "/app/projects/#{context.project.id}/working-copies")

    refute html =~
             ~s(phx-value-id="#{running.working_copy_id}" data-test="designate-main-copy"),
           "the premise failed: the running checkout is not this project's main copy"

    context
    |> Map.put(:running_root, running_root)
    |> Map.put(:agent_root, agent_root)
    |> Map.put(:running, running)
    |> Map.put(:running_socket, running_socket)
    |> Map.put(:agent, agent)
    |> Map.put(:scope, %{context.scope | active_working_copy_id: agent.working_copy_id})
  end

  defp git(context, dir, args),
    do:
      ExecutionContexts.cmd(context.execution_context, "git", args,
        cd: dir,
        stderr_to_stdout: true
      )

  defp war(body) do
    "defmodule BrokenOaths.Diplomacy.War do\n  def declare, do: #{body}\nend\n"
  end

  defp disk(root), do: ExecutionContext.new(:local, root)

  defp write(root, path, content),
    do: :ok = ExecutionContexts.write_file(disk(root), path, content)
end
