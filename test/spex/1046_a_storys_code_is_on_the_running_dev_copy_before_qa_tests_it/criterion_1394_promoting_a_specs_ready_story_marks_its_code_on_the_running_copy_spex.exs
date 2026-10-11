defmodule CodeMySpecSpex.Story1046.Criterion1394Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1394 — Promoting a specs-ready story marks its code on the
  running copy.

  Rule (reworded again by e1174640, 2026-09-29 — the 2026-09-28 wording,
  "a successful promotion marks every specs-ready story it has not yet
  stamped," described `Stories.mark_ready_stories_promoted/2`, which no
  longer exists): a successful promotion stamps the one story it names —
  and only that story — as on the running copy, at the version it
  promoted, once its spex pass. A different specs-ready story, not the one
  named, is left untouched by that same promotion; it is stamped by its
  own promotion, naming it.

  `Stories.mark_story_promoted/4` is the only writer of `promoted_version`
  now, and it takes the one story `promote(scope, story_number)` named. A
  later promotion of the same story is a no-op (the query excludes a story
  with a version already set). `Promotion.RunningCopy.running_copy_check/2`
  reads that stamp directly, so the two facts — promoted, and
  `story_promoted` — are the same fact read from two callers.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.PromotionHelpers, only: [a_promotable_story: 2]
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Promotion.Tools.PromoteSync
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  alias CodeMySpec.Stories
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

  spex "Promoting a specs-ready story marks its code on the running copy",
    criterion: 1394 do
    scenario "the stamp lands once and a later promotion does not repeat it" do
      given_ "a story certified ready for QA, not yet promoted",
             context do
        context = a_promotable_project(context)
        context = CodeMySpecSpex.FullSatisfactionFixtures.apply_up_to_analysis(context)

        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_the_copy"))
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-am", "the story's work"])

        context = CodeMySpecSpex.FullSatisfactionFixtures.apply_qa_readiness_transition(context)

        :ok =
          StoryIssueBag.certify(
            context.scope,
            context.story.id,
            PromotionHelpers.head_of(context, context.agent_root)
          )

        # QA has passed it: promotion comes after QA.
        {:ok, _} = Fixtures.passed_qa_attempt(context.scope, story_id: context.story.id)

        story = Stories.get_story(context.scope, context.story.id)
        assert story.qa_ready_commit, "the premise failed: the story should be certified for QA"
        refute story.promoted_version, "the premise failed: the story should not be promoted yet"

        sibling = a_promotable_story(context, title: "A different story, not the one promoted")
        {:ok, Map.put(context, :sibling, sibling)}
      end

      when_ "a promotion succeeds", context do
        context = analyzers_are_current(context)
        response = promote(context, context.story.number)
        answer_restart_app_ok(context.running_socket)
        {:ok, Map.put(context, :first_promote_response, response)}
      end

      then_ "the story is stamped with the version that promotion carried", context do
        story = Stories.get_story(context.scope, context.story.id)

        assert is_binary(story.promoted_version),
               "the story should carry the promoted version now — promote reported: " <>
                 "#{response_text(context.first_promote_response)}"

        {:ok, Map.put(context, :stamped_version, story.promoted_version)}
      end

      and_ "the sibling story this promotion did not name is left untouched", context do
        sibling = Stories.get_story(context.scope, context.sibling.id)

        refute sibling.specs_ready,
               "a promotion that named one story stamped a different one too — the " <>
                 "project-wide sweep this replaced is gone; only the named story moves"

        refute sibling.promoted_version

        {:ok, context}
      end

      then_ "its code-on-running-copy requirement is satisfied", context do
        text = code_on_running_copy_status(context)

        assert text =~ "[x] **story_promoted**",
               "the stamp should be enough on its own for story_promoted to " <>
                 "read satisfied. Got: #{text}"

        {:ok, context}
      end

      when_ "a later promotion is attempted", context do
        # The first promotion's version commit is on main now, and a copy that
        # does not contain main is refused before anything is analysed
        # (28d72f8a) — so the agent merges main in and its analyzers run at
        # the new HEAD, as they would for any later promotion.
        {_, 0} = git(context, context.agent_root, ["merge", "--ff-only", "-q", "main"])
        context = analyzers_are_current(context)

        response = promote_already_landed(context, context.story.number)

        # Its commit is already on main, so the queue lands it at once with
        # nothing to deploy (2583cc8b0): the running app is not restarted.
        refute_push("restart_app", _payload, 1_000)
        {:ok, Map.put(context, :second_promote_response, response)}
      end

      then_ "the story's stamp does not change — a later promotion does not re-stamp it",
            context do
        story = Stories.get_story(context.scope, context.story.id)

        assert story.promoted_version == context.stamped_version,
               "a story already stamped should keep the version its own promotion " <>
                 "carried, not whatever a later, unrelated promotion happens to be. " <>
                 "Second promote reported: #{response_text(context.second_promote_response)}"

        {:ok, context}
      end
    end
  end

  defp code_on_running_copy_status(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      ListRequirements.execute(
        %{
          entity_type: "story",
          entity_id: to_string(context.story.number),
          requirement_name: "story_promoted"
        },
        frame
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

  defp promote_already_landed(context, story_number) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
    {:reply, response, _} = PromoteSync.execute(%{story_number: story_number}, frame)
    response
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
    PromotionHelpers.stop_the_queue_on_exit(context.project.id)
    running_root = CodeMySpec.TempFile.dir("spex-1394-running")
    {_, 0} = Environments.cmd(context.environment, "mkdir", ["-p", running_root])

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

    # `Promotion.Steps.bump_version/2` reads `version: "X.Y.Z"` out of
    # `HEAD:mix.exs` on the running checkout; without one the merge still
    # lands but mints no version, and stories are stamped only on a
    # non-nil version. See criterion 1174's own copy of this note.
    write(running_root, "mix.exs", ~s(version: "0.1.0"\n))

    {_, 0} = git(context, running_root, ["add", "-A"])
    {_, 0} = git(context, running_root, ["commit", "-q", "-m", "base"])
    {_, 0} = git(context, running_root, ["tag", "-a", "v0.1.0", "-m", "v0.1.0"])

    agent_root = CodeMySpec.TempFile.dir("spex-1394-agent")
    {_, 0} = Environments.cmd(context.environment, "rm", ["-rf", agent_root])

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
    do: Environments.cmd(context.environment, "git", args, cd: dir, stderr_to_stdout: true)

  defp war(body) do
    "defmodule BrokenOaths.Diplomacy.War do\n  def declare, do: #{body}\nend\n"
  end

  defp disk(root), do: Environment.new(:local, root)

  defp write(root, path, content), do: :ok = Environments.write_file(disk(root), path, content)
end
