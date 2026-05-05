defmodule CodeMySpecSpex.Story559.Criterion5892Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5892 — A story can have multiple personas linked, and the
  readiness gate counts them all as satisfying the persona-linkage
  requirement (no upper bound on personas — only rules have a ceiling).

  Covers Rule 3's multi-persona scenario from `examples.md`:
  "Agent links two personas to the story when scenarios cover distinct
  user roles."

  Depends on:
    - `BddRulesChecker.complete?/2` ✓
    - `Personas.link_persona_to_story` ✓
    - `:three_amigos_task_started` shared given ✓
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.BddRules.Tools.AddRule
  alias CodeMySpec.McpServers.BddRules.Tools.AddScenario
  alias CodeMySpec.McpServers.Personas.Tools.CreatePersona
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "story can have multiple personas linked and still satisfy readiness" do
    scenario "evaluate passes when two personas are linked plus a rule with happy + failure scenarios" do
      given_ :persona_exists

      given_ "a second persona is created and linked to the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          CreatePersona.execute(
            %{
              slug: "driver",
              name: "Driver",
              headline: "Fleet driver attempting card transactions"
            },
            frame
          )

        driver = CodeMySpec.Personas.get_persona_by_slug(context.scope, "driver")

        {:ok, _link} =
          CodeMySpec.Personas.link_persona_to_story(context.scope, driver.id, context.story.id)

        {:ok, context}
      end

      given_ "one rule exists with happy + failure scenarios", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        rule_statement = "Suspended cards cannot be used for purchases"

        {:reply, _add_rule, _frame} =
          AddRule.execute(
            %{story_id: context.story.id, statement: rule_statement},
            frame
          )

        {:reply, _happy, _frame} =
          AddScenario.execute(
            %{
              story_id: context.story.id,
              rule_statement: rule_statement,
              title: "Driver attempts purchase with suspended card",
              kind: "happy_path",
              body: "Given context\nWhen action\nThen happy outcome"
            },
            frame
          )

        {:reply, _failure, _frame} =
          AddScenario.execute(
            %{
              story_id: context.story.id,
              rule_statement: rule_statement,
              title: "Suspension status fails to load",
              kind: "failure_path",
              body: "Given context\nWhen action\nThen failure outcome"
            },
            frame
          )

        {:ok, context}
      end

      given_ :three_amigos_task_started

      when_ "the agent calls evaluate_task on the Three Amigos task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "the response indicates the Three Amigos task passed", context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/passed|complete/i,
               "expected response to indicate the task passed, got #{inspect(context.evaluate_response)}"

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
