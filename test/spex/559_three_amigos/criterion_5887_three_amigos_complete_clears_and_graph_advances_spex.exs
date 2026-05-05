defmodule CodeMySpecSpex.Story559.Criterion5887Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5887 — When a story has all readiness conditions met
  (≥1 persona linked, ≥1 rule, every rule has a happy + a failure
  scenario, scenarios > questions), the agent's `evaluate/2` clears
  `three_amigos_complete` and the next `get_next_requirement` no
  longer returns it for this story.

  Happy-path end-to-end spec — every prior criterion exercises a
  failure mode; this one proves the pipeline actually advances when
  the readiness gate passes.

  DRAFT. Depends on:
    - `three_amigos_complete` graph node + delegate checker
      (`ThreeAmigosChecker.complete?/1`) that enforces the readiness
      conditions per `rules.md` Rule "Session readiness gate".
    - `AgentTasks.ThreeAmigos` task module with `command/2` and
      `evaluate/2`.
    - `Rules`, `Questions`, enriched `AcceptanceCriteria` contexts
      with their server APIs and write-through stacks.
    - `AddRule` and `AddScenario` MCP tools (used here to set up
      compliant readiness state through the same surface the agent
      uses in production).
    - Stop-hook routing for `three_amigos_complete` tasks.
    - A `:three_amigos_task_started` shared given mirroring
      `:persona_research_task_started` for the new requirement name.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.BddRules.Tools.AddRule
  alias CodeMySpec.McpServers.BddRules.Tools.AddScenario
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "agent completes Three Amigos end to end" do
    scenario "three_amigos_complete clears and the graph advances past it" do
      given_ :persona_exists

      given_ "one rule with a happy and a failure scenario exists for the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _add_rule_response, _frame} =
          AddRule.execute(
            %{
              "story_id" => to_string(context.story.id),
              "statement" => "Suspended cards cannot be used for purchases"
            },
            frame
          )

        {:reply, _happy_response, _frame} =
          AddScenario.execute(
            %{
              "story_id" => to_string(context.story.id),
              "rule_statement" => "Suspended cards cannot be used for purchases",
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
              "rule_statement" => "Suspended cards cannot be used for purchases",
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

      given_ :three_amigos_task_started

      when_ "the agent fires the stop hook", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post("/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :stop_response, response)}
      end

      then_ "the next requirement is no longer three_amigos_complete for this story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)

        body = response_text(response)

        assert body =~ ~r/requirement|satisfied|complete/i,
               "expected a real discovery response from get_next_requirement"

        story_id = to_string(context.story.id)

        refute body =~ "three_amigos_complete" and body =~ story_id,
               "expected the graph to advance past three_amigos_complete for story #{story_id}, got #{inspect(response)}"

        {:ok, context}
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
