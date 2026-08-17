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
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Every component must be linked to a story, transitively depended on, or in infrastructure_paths" do
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

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

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

        task_id = extract_task_id(response_text(response))

        {:ok, Map.put(context, :task_id, task_id)}
      end

      when_ "the architect writes a proposal that wires SharedKit as a transitive dep of the story-linked surface",
            context do
        app = context.project.module_name || "MyApp"
        story_id = context.story.id

        proposal = """
        # Architecture Proposal

        ## Surface Components

        ### #{app}Web.FeatureLive

        - **Type:** liveview
        - **Description:** Feature page
        - **Stories:** #{story_id}

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

        :ok =
          CodeMySpec.Environments.write_file(
            context.environment,
            Fixtures.proposal_path(),
            proposal
          )

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

      then_ "execution creates a spec stub for the transitively-linked dependency", context do
        app = context.project.module_name || "MyApp"
        spec_path = Fixtures.spec_file(Macro.underscore("#{app}.SharedKit"))

        assert CodeMySpec.Environments.file_exists?(context.environment, spec_path),
               "expected spec stub at #{spec_path} for transitively-linked SharedKit"

        {:ok, context}
      end
    end
  end

  defp extract_task_id(text),
    do: extract_task_id_from(Regex.run(~r/Task ID: `([^`]+)`/, text), text)

  defp extract_task_id_from([_, task_id], _text), do: task_id

  defp extract_task_id_from(_, text),
    do: raise("Could not extract task ID from response: #{inspect(text)}")
end
