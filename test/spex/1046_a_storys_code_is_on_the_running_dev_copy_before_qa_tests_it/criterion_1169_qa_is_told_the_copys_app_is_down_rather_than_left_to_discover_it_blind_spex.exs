defmodule CodeMySpecSpex.Story1046.Criterion1169Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1169 — QA is told the copy's app is down rather than left to
  discover it blind.

  Rule: `QaStory` always brings the story's own copy's app up as part of
  starting — `own_copy_app_url_line/1` calls `AppTransport.ensure_app_running/2`
  live, not a cached status read. If that still comes back anything short of
  `"serving"`, the task is still handed out, with its prompt saying so and
  telling the agent to investigate rather than write a testing brief against
  an address that will refuse the connection.

  This scenario used to live under criterion 1183 (story 1108), titled "A
  story is not ready for QA while its application is down" — asserting QA
  was refused and `PromoteWork` offered instead. That was correct when
  `code_on_running_copy` sat upstream of `qa_complete` (the old order QA
  tested main *after* promotion, so a down app blocked the only checkout
  that mattered and the fix genuinely was to promote). Story 1003 reverses
  that order — QA now runs on the story's own copy *before* promotion — and
  the old assertion became a hole rather than a nicety: offering `PromoteWork`
  here would let an agent stamp `promoted_version` before `qa_complete` was
  ever satisfied, the exact ordering story 1003 exists to prevent. Caught by
  Harness (session 4298eb) reviewing this story's own fix.

  `criterion_1183`'s spex keeps its other two scenarios — the post-promotion
  preview being up, and `promote` itself starting a down app when explicitly
  invoked — both genuinely about what `criterion_1183`'s own text says: "The
  preview app is up after a promotion, and is started if it is not."
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Stories
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The joins go through a real channel, which runs in a process of its own.
  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "QA is told the copy's app is down rather than left to discover it blind",
    criterion: 1169 do
    scenario "the story's own copy is not answering" do
      given_ "a story ready for QA on its own working copy", context do
        context = CodeMySpecSpex.FullSatisfactionFixtures.apply_without_qa_story(context)
        context = this_copy_is_the_running_one(context)
        {:ok, assign_story_to_this_copy(context)}
      end

      given_ "whose app is confirmed down", context do
        report_preview(context, "down")
        {:ok, context}
      end

      when_ "the QA agent asks for its next work", context do
        {:ok, ask_for_next_work(context)}
      end

      then_ "it is still handed the QA task, not refused or redirected", context do
        text = response_text(context.response)

        assert text =~ "QaStory",
               "a down app is a finding for QA to hit and report, not a reason to " <>
                 "hold the task back — QaStory brings the app up itself as part of " <>
                 "starting. Got: #{text}"

        refute text =~ "PromoteWork",
               "promoting here would stamp promoted_version before qa_complete is " <>
                 "satisfied — exactly the ordering story 1003 exists to prevent. " <>
                 "Got: #{text}"

        {:ok, context}
      end

      then_ "starting the task says the app is down and to investigate, not to test",
            context do
        prompt = start_qa_task(context)

        assert prompt =~ "currently `down`" or prompt =~ "could not be started",
               "the prompt should say plainly that the app did not come up. Got: #{prompt}"

        assert prompt =~ "Say so and investigate",
               "the prompt should tell the agent to investigate rather than proceed " <>
                 "as though the app were serving. Got: #{prompt}"

        refute prompt =~ "this working copy's own instance",
               "the prompt should not claim the app is serving. Got: #{prompt}"

        {:ok, context}
      end
    end
  end

  defp ask_for_next_work(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
    {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
    Map.put(context, :response, response)
  end

  # This checkout is the fixture's default working copy — a DB row, not a
  # joined harness channel — so `own_copy_app_url_line/1`'s live
  # `ensure_app_running` dispatch finds no executor holder and answers
  # `{:error, :unreachable}` immediately. No push to simulate: an unregistered
  # checkout and a confirmed-down one land on the same prompt branch, both
  # telling the agent to investigate rather than test.
  defp start_qa_task(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      StartTask.execute(
        %{
          requirement_name: "qa_complete",
          entity_type: "story",
          entity_id: to_string(context.story.number),
          session_id: "spex-1169-#{System.unique_integer([:positive])}"
        },
        frame
      )

    response_text(response)
  end

  defp report_preview(context, status) do
    CodeMySpecSpex.Fixtures.record_preview_status(
      context.scope.active_working_copy_id,
      status
    )

    context
  end

  defp this_copy_is_the_running_one(context) do
    {:ok, view, _html} =
      live(context.conn, "/app/projects/#{context.project.id}/working-copies")

    view
    |> element(
      "[data-test='designate-main-copy'][phx-value-id='#{context.scope.active_working_copy_id}']"
    )
    |> render_click()

    context
  end

  defp assign_story_to_this_copy(context) do
    story = Stories.get_story(context.scope, context.story.id)

    {:ok, story} =
      Stories.update_story(context.scope, story, %{
        working_copy_id: context.scope.active_working_copy_id
      })

    Map.put(context, :story, story)
  end
end
