defmodule CodeMySpecSpex.Story1046.Criterion1510Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1510 — Failed QA is fixed and retested on the same copy.

  Failed QA finishes its review task. Coding submits the story issue fix,
  the story is certified again, and QA opens a fresh review on the same copy.
  The issue remains unresolved until the reviewed story lands; submission,
  rather than premature resolution, releases the next QA pass.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Qa.Tools.SubmitQaResult
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A story that fails QA is retested on the same copy once fixed",
    criterion: 1510 do
    scenario "the retry addresses the same copy the failure was recorded on" do
      given_ "a story ready for QA on its own copy", context do
        context = CodeMySpecSpex.StorySliceHelpers.main_copy(context)
        context = a_registered_copy(context)
        context = CodeMySpecSpex.FullSatisfactionFixtures.apply_up_to_analysis(context)
        context = CodeMySpecSpex.StorySliceHelpers.activate(context)
        context = CodeMySpecSpex.FullSatisfactionFixtures.apply_qa_readiness_transition(context)
        {:ok, context}
      end

      when_ "QA runs, fails, and files a blocking issue", context do
        {prompt, task_id} = start_qa_task(context)

        {:ok, issue} =
          Issues.create_issue(context.scope, %{
            title: "A real defect QA found",
            description: "Something this story's own QA pass turned up.",
            severity: :high,
            story_id: context.story.id
          })

        response = submit_result(context, task_id, "fail", [issue.id])
        refute response.isError, response_text(response)
        {:ok, issue} = Issues.accept_issue(context.scope, issue)

        {:ok,
         context
         |> Map.put(:first_task_id, task_id)
         |> Map.put(:first_prompt, prompt)
         |> Map.put(:issue, issue)
         |> Map.put(:fail_response, response)}
      end

      then_ "qa_complete remains unsatisfied", context do
        text = qa_complete_status(context)

        refute text =~ "[x] **qa_complete**",
               "a failed attempt should leave qa_complete open, not satisfy it. " <>
                 "submit_qa_result reported: #{response_text(context.fail_response)}. " <>
                 "Got: #{text}"

        {:ok, context}
      end

      when_ "coding submits the fixed issue and the story is certified again", context do
        {:ok, submitted} =
          Issues.submit_story_issue(context.scope, context.issue, %{
            revision: String.duplicate("b", 40),
            evidence: "Fixed the defect and verified its regression test on this copy."
          })

        assert submitted.status == :accepted
        refute is_nil(submitted.story_submission_ref)

        context = CodeMySpecSpex.FullSatisfactionFixtures.apply_qa_readiness_transition(context)

        :ok =
          CodeMySpecSpex.Fixtures.StoryIssueBag.certify(
            context.scope,
            context.story.id,
            String.duplicate("b", 40)
          )

        {:ok, context}
      end

      then_ "QA is offered again, on the same copy that recorded the failure", context do
        {prompt, task_id} = start_qa_task(context)

        assert prompt =~ "this working copy's own instance",
               "the retry should still address this checkout's own app, not fall " <>
                 "back to main or a different copy. Got: #{prompt}"

        refute task_id == context.first_task_id,
               "resubmitting should open a fresh task, not resurrect the failed one"

        {:ok, context |> Map.put(:second_prompt, prompt) |> Map.put(:second_task_id, task_id)}
      end

      when_ "the fix is retested and passes", context do
        response = submit_result(context, context.second_task_id, "pass", [])
        refute response.isError, response_text(response)

        {:ok, Map.put(context, :pass_response, response)}
      end

      then_ "qa_complete is now satisfied", context do
        text = qa_complete_status(context)

        assert text =~ "[x] **qa_complete**",
               "the retest passed and should satisfy qa_complete. " <>
                 "submit_qa_result reported: #{response_text(context.pass_response)}. " <>
                 "Got: #{text}"

        {:ok, context}
      end
    end
  end

  # A single joined copy — this criterion is about the fail/retry cycle
  # staying on *one* copy, not about main vs. a coding agent's worktree, so
  # there is no second checkout here the way the promotion-flow criteria need.
  defp a_registered_copy(context) do
    root = CodeMySpec.TempFile.dir("spex-1510-copy")
    {copy, socket} = join_working_copy_socket(context, root, "the coding agent's copy")

    context
    |> Map.put(:copy, copy)
    |> Map.put(:copy_socket, socket)
    |> Map.put(:scope, %{context.scope | active_working_copy_id: copy.working_copy_id})
  end

  # `own_copy_app_url_line/1` dispatches `ensure_app_running` live over the
  # same channel the copy joined with — see criterion 1170's own copy of
  # this pattern for the full rationale. Answered on `context.copy_socket`
  # every time, which is itself the proof this stays one copy: a task
  # resolved against a different copy would push to a socket nothing here
  # answers, and `assert_push` would time out.
  defp start_qa_task(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
    session_id = context[:session_id] || "spex-1510-#{System.unique_integer([:positive])}"

    task =
      Task.async(fn ->
        StartTask.execute(
          %{
            requirement_name: "qa_complete",
            entity_type: "story",
            entity_id: to_string(context.story.number),
            session_id: session_id
          },
          frame
        )
      end)

    assert_push("ensure_app_running", %{"ref" => ref}, 5_000)

    reply_ref =
      Phoenix.ChannelTest.push(context.copy_socket, "ensure_app_running_result", %{
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
    text = response_text(response)

    {text, extract_task_id(text)}
  end

  defp submit_result(context, task_id, status, issue_ids) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      SubmitQaResult.execute(
        %{
          task_id: task_id,
          status: status,
          scenarios: [
            %{name: "The reported scenario", status: status, observation: "Recorded by spex."}
          ],
          issue_ids: issue_ids
        },
        frame
      )

    response
  end

  defp qa_complete_status(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      ListRequirements.execute(
        %{
          entity_type: "story",
          entity_id: to_string(context.story.number),
          requirement_name: "qa_complete"
        },
        frame
      )

    response_text(response)
  end

  defp extract_task_id(text) do
    text
    |> then(&Regex.run(~r/Task ID: `([^`]+)`/, &1))
    |> task_id_from_match(text)
  end

  defp task_id_from_match([_, id], _text), do: id

  defp task_id_from_match(_no_match, text),
    do: flunk("start_task's response named no task id. Got: #{text}")
end
