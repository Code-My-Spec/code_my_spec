defmodule CodeMySpecSpex.Story559.Criterion5888Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5888 — When Three Amigos runs on a story with no suitable
  persona in the library, the agent calls `add_persona` to create a
  lightweight record, completes the readiness work, and the graph
  surfaces `personas_complete` as the new research gap that blocks
  forward progress.

  End-to-end coverage of the persona-creation → research-deferral
  flow. Proves Three Amigos does NOT run persona research inline
  (per rules.md "Persona research is not inline" / "Persona linkage
  required") — the lightweight persona record is created during the
  Three Amigos task, and full research surfaces as a separate
  `personas_complete` requirement on the next graph pass.

  Surface signal for the readiness check: `three_amigos_complete` is
  `validation_type: :manual`, so the stop hook skips its checker. The
  agent calls `evaluate_task` explicitly; a "Passed" response is the
  proof that `BddRulesChecker.complete?` accepted rule + happy/failure
  scenarios + persona link. The graph node itself reports as `[ ]`
  via `ListRequirements` because the unsatisfied `personas_complete`
  clamps the entire downstream chain.

  DRAFT. Depends on:
    - Everything criterion 5161 depends on (`AgentTasks.ThreeAmigos`,
      `three_amigos_complete` node + `ThreeAmigosChecker`, `AddRule`
      and `AddScenario` MCP tools, stop-hook routing for the
      `three_amigos_complete` task, the `Rules` /
      `AcceptanceCriteria` write-through stack).
    - `:three_amigos_task_started` shared given mirroring
      `:persona_research_task_started` for the new requirement name.
    - `personas_complete` graph node + `PersonasChecker.complete?/1`
      (exists per Story 560).
    - `add_persona` is implemented as the existing `CreatePersona`
      MCP tool (same record shape — identity + metadata, no research
      artifacts). `link_persona` MCP tool may not exist yet; this
      spec uses the `Personas` context call as a substitute, matching
      the `:persona_exists` shared given pattern.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.BddRules.Tools.AddRule
  alias CodeMySpec.McpServers.BddRules.Tools.AddScenario
  alias CodeMySpec.McpServers.Personas.Tools.CreatePersona
  alias CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.StoryHelpers

  @endpoint CodeMySpecLocalWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Three Amigos creates lightweight persona; personas_complete surfaces next" do
    scenario "agent adds persona inline, finishes Three Amigos, graph advances to personas_complete" do
      given_ "the project's upstream chain is satisfied", context do
        # Without this, qa_setup → component_linked → three_amigos_complete
        # would all clamp regardless of the readiness work.
        {:ok, CodeMySpecSpex.FullSatisfactionFixtures.apply(context)}
      end

      given_ "a separate story exists linked to its own leaf surface with no extra personas linked",
             context do
        surface_module = "ThreeAmigosSurfaceLive"
        spec_path = ".code_my_spec/spec/three_amigos_surface_live.spec.md"
        impl_path = "lib/three_amigos_surface_live.ex"

        :ok =
          Environments.write_file(
            context.environment,
            spec_path,
            Content.liveview_spec(surface_module, dependencies: [])
          )

        :ok =
          Environments.write_file(context.environment, impl_path, Content.impl_file(surface_module))

        {:ok, sync_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        story =
          StoryHelpers.create_and_link(context.scope, surface_module,
            title: "Story driving lightweight persona creation",
            description: "Drives Three Amigos with no pre-existing persona in the account library.",
            acceptance_criteria: ["Three Amigos drives lightweight persona creation"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      given_ :three_amigos_task_started

      when_ "the agent calls add_persona for ops_lead", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, create_response, _frame} =
          CreatePersona.execute(
            %{
              slug: "ops_lead",
              name: "Ops Lead",
              headline: "Operations lead managing fleet driver issues"
            },
            frame
          )

        {:ok, Map.put(context, :persona_id, extract_persona_id(create_response))}
      end

      when_ "the agent links ops_lead to the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _link_response, _frame} =
          LinkPersonaToStory.execute(
            %{persona_id: context.persona_id, story_id: context.story.id},
            frame
          )

        {:ok, context}
      end

      when_ "the agent populates the story with one rule and a happy + failure scenario",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        rule_statement = "Suspended cards cannot be used for purchases"

        {:reply, _add_rule_response, _frame} =
          AddRule.execute(
            %{
              "story_id" => to_string(context.story.id),
              "statement" => rule_statement
            },
            frame
          )

        {:reply, _happy_response, _frame} =
          AddScenario.execute(
            %{
              "story_id" => to_string(context.story.id),
              "rule_statement" => rule_statement,
              "title" => "Driver attempts purchase with suspended card",
              "kind" => "happy_path",
              "body" => """
              Given the driver's card is suspended
              When the driver attempts a purchase at point of sale
              Then the purchase is declined
              """
            },
            frame
          )

        {:reply, _failure_response, _frame} =
          AddScenario.execute(
            %{
              "story_id" => to_string(context.story.id),
              "rule_statement" => rule_statement,
              "title" => "Suspension status fails to load at point of sale",
              "kind" => "failure_path",
              "body" => """
              Given the driver's card status cannot be retrieved
              When the driver attempts a purchase at point of sale
              Then the purchase is declined for safety
              """
            },
            frame
          )

        {:ok, context}
      end

      when_ "the agent calls evaluate_task for the Three Amigos task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "evaluate_task accepts the readiness gate and personas_complete clamps the chain",
            context do
        eval_body = response_text(context.evaluate_response)

        assert eval_body =~ ~r/^# .+: Passed/m,
               "expected evaluate_task to mark Three Amigos passed, got #{inspect(context.evaluate_response)}"

        refute eval_body =~ ~r/Needs work/,
               "expected no needs-work feedback, got #{inspect(context.evaluate_response)}"

        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, list_response, _frame} = ListRequirements.execute(%{}, frame)
        list_body = response_text(list_response)

        assert list_body =~ ~r/\[ \]\s+\*\*personas_complete\*\*/,
               "expected personas_complete to be unsatisfied at the project level, got #{inspect(list_response)}"

        assert list_body =~ ~r/\[ \]\s+\*\*three_amigos_complete\*\*/,
               "expected three_amigos_complete to be clamped to unsatisfied via personas_complete cascade, got #{inspect(list_response)}"

        {:ok, context}
      end
    end
  end

  defp extract_persona_id(response) do
    case Regex.run(~r/\bid: `([^`]+)`/, response_text(response)) do
      [_, id] -> id
      _ -> raise "Could not extract persona id from response: #{inspect(response)}"
    end
  end
end
