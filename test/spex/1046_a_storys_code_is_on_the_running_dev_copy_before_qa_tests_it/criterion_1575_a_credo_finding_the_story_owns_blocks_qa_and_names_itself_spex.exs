defmodule CodeMySpecSpex.Story1046.Criterion1575Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1575 — Promotion is offered only after the story passes QA (failure
  path: a bare analyzer problem, no accepted issue).

  Rule: QA runs only once the story carries no open issues and no analyzer
  problems on its copy (story 1003, Three Amigos, phase 2 of story 1108,
  John: "I want all the problems gone, all the issues fixed, then we run QA").

  A story with zero accepted issues but one credo finding on its own working
  copy is exactly the case `problems_resolved` exists for. It has no
  dedicated task of its own — `FixStoryIssues` was reused, since inventing a
  second story-scoped "go clean up" task for one more source of blockers is
  the wrong kind of new surface. The risk that reuse creates is the "claim
  the task, find no issues, tap out, get offered the same task forever" spin
  this project has been burned by before (94327fe2): an agent offered
  `FixStoryIssues` while only a credo finding blocks release has to be told
  about the finding directly, not left staring at an empty issue list.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Problems
  alias CodeMySpec.Stories
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A story blocked only by a credo finding is offered a task that names it, not QA",
       criterion: 1575 do
    scenario "a story blocked only by a credo finding on its own copy, until it's fixed" do
      given_ "a story with clean specs, no accepted issues, and one credo finding on its own working copy",
             context do
        context = FullSatisfactionFixtures.apply_up_to_analysis(context)
        context = FullSatisfactionFixtures.apply_qa_readiness_transition(context)

        # `problems_resolved`/`ProblemsChecker` read the *story's* own
        # `working_copy_id`, not whichever copy is asking — the same
        # scoping `story_issues_resolved` uses, and deliberately, so a
        # problem on some other copy can never gate this story. The
        # fixture chain above never assigns a story to a copy, so it has
        # to be set explicitly here. `context.story` is the lightweight map
        # `StoryHelpers` returns, not the real struct `update_story/3` needs.
        story = Stories.get_story(context.scope, context.story.id)

        {:ok, story} =
          Stories.update_story(context.scope, story, %{
            working_copy_id: context.scope.active_working_copy_id
          })

        context = Map.put(context, :story, story)

        # On disk, not just in the DB: `EvaluateTask` syncs files first
        # (`Evaluator.sync_files/1`), and `FileSync.sync/2` clears problems
        # recorded against a path that sync no longer finds
        # (`Problems.clear_problems_for_missing_files/2`) — correct for a
        # real orphaned finding, and exactly what would silently clear this
        # one if the file it names were never actually written.
        :ok =
          Environments.write_file(context.environment, "lib/example/widget.ex", """
          defmodule Example.Widget do
            def render, do: :ok
          end
          """)

        {:ok, [problem]} = Problems.create_problems(context.scope, [credo_finding()])

        {:ok, Map.put(context, :problem, problem)}
      end

      when_ "the coding agent asks for its next work", context do
        {:ok, ask_for_next_work(context)}
      end

      then_ "it is offered FixStoryIssues via problems_resolved, not QaStory", context do
        text = response_text(context.response)

        assert text =~ "FixStoryIssues",
               "a story blocked only by a credo finding should still be offered a " <>
                 "coding task, not left with nothing actionable. Got: #{text}"

        assert text =~ "problems_resolved",
               "the offer should name the requirement actually blocking, so an " <>
                 "agent can tell this apart from an ordinary issues cleanup. Got: #{text}"

        refute text =~ "QaStory",
               "QA should not be offered while this story's own working copy " <>
                 "carries a blocking analyzer problem. Got: #{text}"

        {:ok, context}
      end

      then_ "starting that task's prompt names the finding by file, line and message",
            context do
        context = start_problems_resolved_task(context)
        prompt = context.prompt

        assert prompt =~ "lib/example/widget.ex:17",
               "the task's prompt should name the finding's file and line directly, " <>
                 "not leave the agent to discover it another way. Got: #{prompt}"

        assert prompt =~ "Function is too complex",
               "the task's prompt should name the finding's message. Got: #{prompt}"

        {:ok, context}
      end

      then_ "evaluating that task fails while the finding remains", context do
        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
          )

        text = response_text(response)

        assert text =~ "Needs work",
               "evaluating the task should refuse while the credo finding is still on " <>
                 "this story's own working copy — an agent that calls evaluate_task " <>
                 "too early must not be told it's done. Got: #{text}"

        assert text =~ "this task remains open",
               "the refusal should leave the task active rather than close it out from " <>
                 "under the agent. Got: #{text}"

        assert text =~ "blocking problem",
               "the refusal should say why, not just that it failed. Got: #{text}"

        {:ok, context}
      end

      when_ "the finding is fixed and cleared", context do
        {:ok, _count} =
          Problems.clear_problems_for_source(context.scope, [source: "credo"], :all)

        {:ok, ask_for_next_work(context)}
      end

      then_ "QA is offered instead", context do
        text = response_text(context.response)

        assert text =~ "QaStory",
               "once the finding clears, QA should be the next offer. Got: #{text}"

        refute text =~ "FixStoryIssues",
               "the story is no longer blocked, so the old offer should not persist. " <>
                 "Got: #{text}"

        {:ok, context}
      end
    end
  end

  defp ask_for_next_work(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
    {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
    Map.put(context, :response, response)
  end

  # Through `start_task`, the surface an agent actually calls, rather than
  # `FixStoryIssues.command/2` directly — a spex observes rendered output from
  # the public surface, not a task module's internals. `session_id` is any
  # unique string: `StartTask`'s owner resolution lazily registers a session
  # row for one it has not seen, the same self-heal path a real first call
  # from a fresh Claude Code session takes.
  defp start_problems_resolved_task(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
    session_id = "spex-1575-#{System.unique_integer([:positive])}"

    {:reply, response, _frame} =
      StartTask.execute(
        %{
          requirement_name: "problems_resolved",
          entity_type: "story",
          entity_id: to_string(context.story.number),
          session_id: session_id
        },
        frame
      )

    text = response_text(response)

    context
    |> Map.put(:prompt, text)
    |> Map.put(:task_id, extract_task_id(text))
    |> Map.put(:session_id, session_id)
  end

  defp extract_task_id(text) do
    text
    |> then(&Regex.run(~r/Task ID: `([^`]+)`/, &1))
    |> task_id_from_match(text)
  end

  defp task_id_from_match([_, id], _text), do: id
  defp task_id_from_match(_no_match, text), do: flunk("start_task's response named no task id. Got: #{text}")

  defp credo_finding do
    %{
      severity: :error,
      source_type: :static_analysis,
      source: "credo",
      file_path: "lib/example/widget.ex",
      line: 17,
      message: "Function is too complex",
      category: "readability",
      rule: "Credo.Check.Refactor.CyclomaticComplexity",
      metadata: %{}
    }
  end
end
