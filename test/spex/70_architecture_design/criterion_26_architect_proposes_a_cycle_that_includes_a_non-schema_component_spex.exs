defmodule CodeMySpecSpex.Story70.Criterion5309Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 5309 — Architect proposes a cycle that includes a non-schema component.

  When a dependency cycle involves at least one context-typed component the
  validator rejects the proposal, names the cycle path in the feedback,
  and execution does not run.

  Surface: `start_task` then `evaluate_task`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Cyclic dependencies among non-schema components are rejected", criterion: 26 do
    scenario "Architect proposes a cycle that includes a non-schema component" do
      given_ "an unsatisfied story exists on the project", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Story — stories and criteria",
            description: "Stories and criteria",
            acceptance_criteria: ["Stories and criteria criterion"]
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

      when_ "the architect declares a three-way cycle among context components", context do
        app = context.project.module_name || "MyApp"
        story_number = context.story.number

        # Stories depends on AcceptanceCriteria depends on Rules depends on Stories
        # All three are typed as context — Rule 4 forbids this cycle

        proposal = """
        # Architecture Proposal

        ## Surface Components

        ### #{app}Web.StoryLive.Index

        - **Type:** liveview
        - **Description:** Story list page
        - **Stories:** #{story_number}

        ## Contexts

        ### #{app}.Stories

        - **Type:** context
        - **Description:** Stories domain

        ### #{app}.AcceptanceCriteria

        - **Type:** context
        - **Description:** Acceptance criteria domain

        ### #{app}.Rules

        - **Type:** context
        - **Description:** BDD rules domain

        ## Dependencies

        - #{app}Web.StoryLive.Index -> #{app}.Stories
        - #{app}.Stories -> #{app}.AcceptanceCriteria
        - #{app}.AcceptanceCriteria -> #{app}.Rules
        - #{app}.Rules -> #{app}.Stories
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

      then_ "the validator rejects the proposal", context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/needs work/i,
               "expected rejection for context-component cycle, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "the rejection feedback names the cycle path", context do
        body = response_text(context.evaluate_response)

        # The feedback should name the cycle path: Stories → AcceptanceCriteria → Rules → Stories
        assert body =~ ~r/circular|cycle/i,
               "expected cycle reference in feedback, got: #{inspect(body)}"

        assert body =~ "Stories",
               "expected cycle path to mention Stories, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "execution does not run", context do
        app = context.project.module_name || "MyApp"

        # No spec stubs should be created when execution is blocked by validation
        spec_path = Fixtures.spec_file(Macro.underscore("#{app}.Stories"))

        refute CodeMySpec.ExecutionContexts.file_exists?(context.execution_context, spec_path),
               "expected no spec stub at #{spec_path} when proposal was rejected"

        {:ok, context}
      end
    end
  end
end
