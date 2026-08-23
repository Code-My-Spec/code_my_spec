defmodule CodeMySpecSpex.Story70.Criterion5659Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 5659 — Architect attempts to execute a proposal that leaves a component as an orphan.

  When a proposal contains a component that is not linked to a story,
  not depended on by a story-linked component, and not present in
  `infrastructure_paths`, the validator rejects the proposal, names
  the orphan in the feedback, and execution does not run (no spec
  stubs are created).

  Surface: `start_task` then `evaluate_task` (routes to
  `ArchitectureDesign.evaluate/2` which validates the proposal).
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
    scenario "Architect attempts to execute a proposal that leaves a component as an orphan" do
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
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
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

        task_id = extract_task_id!(response_text(response))

        {:ok, Map.put(context, :task_id, task_id)}
      end

      when_ "the architect writes a proposal whose context list includes an unlinked, undepended component",
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

        ### #{app}.LeftoverKit

        - **Type:** context
        - **Description:** Helper kit not linked to any story and not depended on

        ## Dependencies

        - #{app}Web.FeatureLive -> #{app}.Features
        """

        :ok =
          CodeMySpec.Environments.write_file(
            context.environment,
            Fixtures.proposal_path(),
            proposal
          )

        {:ok, context}
      end

      when_ "the architect calls evaluate_task without resolving the orphan", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "the validator rejects the proposal", context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/needs work/i,
               "expected a needs-work rejection, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "the rejection feedback names the orphaned component", context do
        body = response_text(context.evaluate_response)
        app = context.project.module_name || "MyApp"
        orphan_name = "#{app}.LeftoverKit"

        assert body =~ orphan_name,
               "expected rejection feedback to name #{orphan_name}, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "no spec stubs are created", context do
        app = context.project.module_name || "MyApp"

        for module_name <- [
              "#{app}Web.FeatureLive",
              "#{app}.Features",
              "#{app}.LeftoverKit"
            ] do
          spec_path = Fixtures.spec_file(Macro.underscore(module_name))

          refute CodeMySpec.Environments.file_exists?(context.environment, spec_path),
                 "expected no spec stub at #{spec_path} when proposal was rejected"
        end

        {:ok, context}
      end
    end
  end
end
