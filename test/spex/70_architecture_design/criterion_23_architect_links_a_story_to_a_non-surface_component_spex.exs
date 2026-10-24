defmodule CodeMySpecSpex.Story70.Criterion5292Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 5292 — Architect links a story to a non-surface component.

  When a proposal links a story to an internal (non-surface) component the
  validator accepts the proposal but includes a warning in the evaluation
  feedback naming the story and its non-surface link.

  Surface: `start_task` then `evaluate_task` (routes to
  `ArchitectureDesign.evaluate/2`).
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Surface components are the preferred linkage target", criterion: 23 do
    scenario "Architect links a story to a non-surface component" do
      given_ "an unsatisfied story exists on the project", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Story — architecture design",
            description: "Architecture design",
            acceptance_criteria: ["Architecture design criterion"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context, execution_context: :in_memory)}
      end

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        HarnessHooks.post_hook(context, "session-start", %{"session_id" => session_id})

        {:ok, Map.put(context, :session_id, session_id)}
      end

      given_ "a task is started for architecture_designed", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "architecture_designed",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        task_id = extract_task_id!(response_text(response))

        {:ok, Map.put(context, :task_id, task_id)}
      end

      when_ "the architect writes a proposal linking the story to an internal context component",
            context do
        app = context.project.module_name || "MyApp"
        story_number = context.story.number

        # The story is linked to AgentTasks (an internal context module), not a surface.
        # Per Rule 2, this should be accepted with a warning, not rejected.
        proposal = """
        # Architecture Proposal

        ## Surface Components

        ### #{app}Web.DesignLive

        - **Type:** liveview
        - **Description:** Architecture design surface (no story link — story is on context)

        ## Contexts

        ### #{app}.AgentTasks

        - **Type:** context
        - **Description:** Agent task orchestration — internal, not a user surface
        - **Stories:** #{story_number}

        ## Dependencies

        - #{app}Web.DesignLive -> #{app}.AgentTasks
        """

        :ok =
          CodeMySpec.ExecutionContexts.write_file(
            context.execution_context,
            Fixtures.proposal_path(),
            proposal
          )

        {:ok, context}
      end

      when_ "the architect calls evaluate_task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.task_id, session_id: context.session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "the validator accepts the proposal", context do
        body = response_text(context.evaluate_response)

        # Rule 2: non-surface links warn but do not block execution
        refute body =~ ~r/needs work/i,
               "expected non-surface link to produce a warning, not a rejection, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "execution proceeds", context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/passed/i,
               "expected Passed (execution proceeded), got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "the evaluation feedback contains a warning naming the story and its non-surface link",
            context do
        body = response_text(context.evaluate_response)
        story_number = to_string(context.story.number)

        assert body =~ ~r/warning/i,
               "expected a surface-preference warning in the feedback, got: #{inspect(body)}"

        assert body =~ "story #{story_number}",
               "expected warning to name story #{story_number}, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end
