defmodule CodeMySpecSpex.Story559.Criterion5162Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5162 — When Three Amigos runs on a story with no suitable
  persona in the library, the agent calls `add_persona` to create a
  lightweight record, completes the readiness gate, and the next
  `get_next_requirement` surfaces `personas_complete` naming the
  new persona as missing research artifacts.

  End-to-end coverage of the persona-creation → research-deferral
  flow. Proves Three Amigos does NOT run persona research inline
  (per rules.md "Persona research is not inline" / "Persona linkage
  required") — the lightweight persona record is created during the
  Three Amigos task, and full research surfaces as a separate
  `personas_complete` requirement on the next graph pass.

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

  import_givens CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.BddRules.Tools.AddRule
  alias CodeMySpec.McpServers.BddRules.Tools.AddScenario
  alias CodeMySpec.McpServers.Personas.Tools.CreatePersona
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Three Amigos creates lightweight persona; personas_complete surfaces next" do
    scenario "agent adds persona inline, finishes Three Amigos, graph advances to personas_complete" do
      given_ "a story exists with no AC and no personas linked", context do
        story =
          Fixtures.story_fixture(context.scope,
            title: "Story driving lightweight persona creation",
            description: "Drives Three Amigos with no pre-existing persona in the account library."
          )

        {:ok, Map.put(context, :story, story)}
      end

      given_ :three_amigos_task_started

      when_ "the agent calls add_persona for ops_lead", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          CreatePersona.execute(
            %{
              slug: "ops_lead",
              name: "Ops Lead",
              headline: "Operations lead managing fleet driver issues"
            },
            frame
          )

        persona = CodeMySpec.Personas.get_persona_by_slug(context.scope, "ops_lead")
        {:ok, Map.put(context, :persona, persona)}
      end

      when_ "the agent links ops_lead to the story", context do
        {:ok, _link} =
          CodeMySpec.Personas.link_persona_to_story(
            context.scope,
            context.persona.id,
            context.story.id
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

      when_ "the agent fires the stop hook for the Three Amigos task", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post("/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :stop_response, response)}
      end

      then_ "three_amigos_complete is satisfied for the story and personas_complete is now unsatisfied",
            context do
        # GetNextRequirement is gated on project_setup which isn't satisfied
        # in the test environment, so it would just return project_setup.
        # ListRequirements walks the full graph and renders satisfaction as
        # `[x]` / `[ ]` checkboxes — that lets us confirm both ends of the
        # state shift in one call: Three Amigos cleared for THIS story, and
        # personas_complete is now the active research gap (unsatisfied
        # because the lightweight ops_lead record has no summary.md /
        # sources.md yet — exactly the deferred-research model).
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListRequirements.execute(%{}, frame)

        body = response_text(response)

        assert body =~ ~r/\[x\]\s+\*\*three_amigos_complete\*\*/,
               "expected three_amigos_complete to be satisfied for the story, got #{inspect(response)}"

        assert body =~ ~r/\[ \]\s+\*\*personas_complete\*\*/,
               "expected personas_complete to be unsatisfied at the project level, got #{inspect(response)}"

        :ok
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: text} -> text
      %{"text" => text} -> text
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end
