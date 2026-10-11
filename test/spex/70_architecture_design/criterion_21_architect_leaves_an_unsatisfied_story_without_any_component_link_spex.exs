defmodule CodeMySpecSpex.Story70.Criterion5290Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 5290 — Architect leaves an unsatisfied story without any component link.

  When a proposal omits at least one unsatisfied story the validator rejects
  it, names the unlinked story in the feedback, and execution does not run
  (no spec stubs are created, no story-component links are persisted).

  Surface: `start_task` then `evaluate_task` (routes to
  `ArchitectureDesign.evaluate/2` which validates the proposal).
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Every unsatisfied story must be linked before the proposal can execute", criterion: 21 do
    scenario "Architect leaves an unsatisfied story without any component link" do
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

      when_ "the architect writes a proposal that links only two of three stories",
            context do
        app = context.project.module_name || "MyApp"
        story_a_number = context.story_a.number
        story_b_number = context.story_b.number

        # story_c is intentionally omitted from all surface component mappings

        proposal = """
        # Architecture Proposal

        ## Surface Components

        ### #{app}Web.FeatureOneLive

        - **Type:** liveview
        - **Description:** Feature one page
        - **Stories:** #{story_a_number}

        ### #{app}Web.FeatureTwoLive

        - **Type:** liveview
        - **Description:** Feature two page
        - **Stories:** #{story_b_number}

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

      then_ "the validator rejects the proposal", context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/needs work/i,
               "expected a needs-work rejection, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "the rejection feedback names the unlinked story", context do
        body = response_text(context.evaluate_response)
        story_c = to_string(context.story_c.number)

        assert body =~ story_c,
               "expected rejection feedback to name story #{story_c}, got: #{inspect(body)}"

        refute body =~ to_string(context.story_c.id),
               "the rejection should not carry the story's id: #{inspect(body)}"

        {:ok, context}
      end

      then_ "no spec stubs are created", context do
        app = context.project.module_name || "MyApp"

        for module_name <- [
              "#{app}Web.FeatureOneLive",
              "#{app}Web.FeatureTwoLive",
              "#{app}.Features"
            ] do
          spec_path = Fixtures.spec_file(Macro.underscore(module_name))

          refute Environments.file_exists?(
                   Environment.new(:local, context.harness.root),
                   spec_path
                 ),
                 "expected no spec stub at #{spec_path} when proposal was rejected"
        end

        {:ok, context}
      end
    end
  end
end
