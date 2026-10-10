defmodule CodeMySpecSpex.Story70.Criterion5658Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 5658 — Architect resolves an orphan by adding a dependency edge from a story-linked component.

  When a proposal includes a context that has no direct story link but
  is reachable as a transitive dependency of a story-linked surface
  component, the validator accepts the proposal and execution writes
  spec stubs for every component (including the dependency).

  Surface: `start_task` then `evaluate_task` (routes to
  `ArchitectureDesign.evaluate/2`).
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.ListComponents
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Every component must be linked to a story, transitively depended on, or in infrastructure_paths",
    criterion: 32 do
    scenario "Architect resolves an orphan by adding a dependency edge from a story-linked component" do
      given_ "an unsatisfied story exists on the project", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Story A — feature one",
            description: "Story A description",
            acceptance_criteria: ["Story A criterion"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        HarnessHooks.post_hook(context, "session-start", %{"session_id" => session_id})

        {:ok, Map.put(context, :session_id, session_id)}
      end

      given_ "a task is started for architecture_designed", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "architecture_designed",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        task_id = extract_task_id!(response_text(response))

        {:ok, Map.put(context, :task_id, task_id)}
      end

      when_ "the architect writes a proposal that wires SharedKit as a transitive dep of the story-linked surface",
            context do
        app = context.project.module_name || "MyApp"
        story_number = context.story.number

        proposal = """
        # Architecture Proposal

        ## Surface Components

        ### #{app}Web.FeatureLive

        - **Type:** liveview
        - **Description:** Feature page
        - **Stories:** #{story_number}

        ## Contexts

        ### #{app}.Features

        - **Type:** context
        - **Description:** Feature domain

        ### #{app}.SharedKit

        - **Type:** context
        - **Description:** Shared helpers — not directly story-linked, reached via dep edge

        ## Dependencies

        - #{app}Web.FeatureLive -> #{app}.Features
        - #{app}.Features -> #{app}.SharedKit
        """

        HarnessHooks.write_file(context, Fixtures.proposal_path(), proposal)

        {:ok, context}
      end

      when_ "the architect calls evaluate_task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "the validator accepts the proposal", context do
        body = response_text(context.evaluate_response)

        refute body =~ ~r/needs work/i,
               "expected proposal to be accepted, but got: #{inspect(body)}"

        assert body =~ ~r/passed/i,
               "expected Passed in the evaluate response, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "execution records the transitively-linked dependency", context do
        app = context.project.module_name || "MyApp"

        {:reply, listed, _frame} =
          ListComponents.execute(
            %{},
            %Frame{assigns: %{current_scope: context.scope}}
          )

        for module_name <- ["#{app}.SharedKit"] do
          assert response_text(listed) =~ module_name,
                 "expected transitively-linked #{module_name} to be recorded by execution"
        end

        {:ok, context}
      end
    end
  end
end
