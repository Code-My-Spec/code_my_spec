defmodule CodeMySpecSpex.Story70.Criterion5312Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 5312 — Architect declares dependencies that all resolve.

  When every declared dependency references a component that either exists
  in the database already or is defined in the proposal, the validator
  accepts the proposal and execution persists the dependency edges.

  Surface: `start_task`, `execute_proposal`, then `evaluate_task`.

  `execute_proposal` is in the middle because this criterion needs a component
  already in the database — that is the half of "resolves" that is not satisfied
  by the proposal itself. A project with components is being *revised*, and a
  revision session will not auto-execute a proposal that may predate the
  architect's incremental edits. Applying a rewrite there is what
  `execute_proposal` is for, and it is what the gate's own feedback tells the
  architect to call.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias Anubis.Server.Frame
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Every declared dependency must reference a known component", criterion: 29 do
    scenario "Architect declares dependencies that all resolve" do
      given_ "the database already contains the Stories component", context do
        app = context.project.module_name || "MyApp"

        stories_component =
          ComponentHelpers.create(context.scope,
            module_name: "#{app}.Stories",
            name: "Stories",
            type: "context",
            description: "Stories domain"
          )

        {:ok, Map.put(context, :stories_component, stories_component)}
      end

      given_ "an unsatisfied story exists on the project", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Story — view story list",
            description: "Story list view",
            acceptance_criteria: ["List view criterion"]
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

      when_ "the architect declares a dependency on the existing Stories component", context do
        app = context.project.module_name || "MyApp"
        story_number = context.story.number

        # StoryLive.Index depends on Stories which already exists in the DB
        proposal = """
        # Architecture Proposal

        ## Surface Components

        ### #{app}Web.StoryLive.Index

        - **Type:** liveview
        - **Description:** Story list page
        - **Stories:** #{story_number}

        ## Contexts

        ## Dependencies

        - #{app}Web.StoryLive.Index -> #{app}.Stories
        """

        :ok =
          CodeMySpec.ExecutionContexts.write_file(
            context.execution_context,
            Fixtures.proposal_path(),
            proposal
          )

        executed =
          ToolLibrary.run("execute_proposal", %{}, %{scope: context.scope})

        {:ok, Map.put(context, :execute_response, executed)}
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

      then_ "the validator resolves every declared dependency to a known component", context do
        body = response_text(context.execute_response)

        assert match?({:ok, _}, context.execute_response),
               "the proposal was refused, so no dependency was resolved either way: " <>
                 inspect(body)

        refute body =~ ~r/dangling|unresolved|not found/i,
               "expected all dependencies to resolve, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "the validator accepts the proposal", context do
        body = response_text(context.evaluate_response)

        refute body =~ ~r/needs work/i,
               "expected proposal to be accepted, got: #{inspect(body)}"

        assert body =~ ~r/passed/i,
               "expected Passed for proposal with valid dependencies, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end
