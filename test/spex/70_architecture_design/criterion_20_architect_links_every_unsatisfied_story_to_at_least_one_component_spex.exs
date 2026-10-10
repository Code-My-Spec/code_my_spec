defmodule CodeMySpecSpex.Story70.Criterion5289Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 5289 — Architect links every unsatisfied story to at least one component.

  When a proposal maps every unsatisfied story to a surface component the
  validator accepts it, spec stubs are created for new components, and
  every story-to-component association is persisted (observable: stories
  no longer surface as needing a component link).

  Surface: `start_task` (returns the work prompt + task ID footer) then
  `evaluate_task` (routes to `ArchitectureDesign.evaluate/2` which reads
  the proposal from the environment file).
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

  spex "Every unsatisfied story must be linked before the proposal can execute", criterion: 20 do
    scenario "Architect links every unsatisfied story to at least one component" do
      given_ "three unsatisfied stories exist on the project", context do
        story_a =
          StoryHelpers.create_story(context.scope,
            title: "Story A — feature one",
            description: "Story A description",
            acceptance_criteria: ["Story A criterion"]
          )

        story_b =
          StoryHelpers.create_story(context.scope,
            title: "Story B — feature two",
            description: "Story B description",
            acceptance_criteria: ["Story B criterion"]
          )

        story_c =
          StoryHelpers.create_story(context.scope,
            title: "Story C — feature three",
            description: "Story C description",
            acceptance_criteria: ["Story C criterion"]
          )

        {:ok,
         Map.merge(context, %{
           story_a: story_a,
           story_b: story_b,
           story_c: story_c
         })}
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

      when_ "the architect writes a proposal that links every story to a surface component",
            context do
        app = context.project.module_name || "MyApp"
        story_a_number = context.story_a.number
        story_b_number = context.story_b.number
        story_c_number = context.story_c.number

        proposal = """
        # Architecture Proposal

        ## Surface Components

        ### #{app}Web.FeatureOneLive

        - **Type:** liveview
        - **Description:** Feature one page
        - **Stories:** #{story_a_number}

        ### #{app}Web.FeatureTwoLive

        - **Type:** liveview
        - **Description:** Feature two and three page
        - **Stories:** #{story_b_number}, #{story_c_number}

        ## Contexts

        ### #{app}.Features

        - **Type:** context
        - **Description:** Core features domain

        ## Dependencies

        - #{app}Web.FeatureOneLive -> #{app}.Features
        - #{app}Web.FeatureTwoLive -> #{app}.Features
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

      then_ "execution records the new components", context do
        app = context.project.module_name || "MyApp"

        {:reply, listed, _frame} =
          ListComponents.execute(
            %{},
            %Frame{assigns: %{current_scope: context.scope}}
          )

        for module_name <- [
              "#{app}Web.FeatureOneLive",
              "#{app}Web.FeatureTwoLive",
              "#{app}.Features"
            ] do
          assert response_text(listed) =~ module_name,
                 "expected component #{module_name} to be recorded by execution"
        end

        {:ok, context}
      end
    end
  end
end
