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
  alias CodeMySpec.ToolLibrary

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "story can have multiple personas linked and still satisfy readiness", criterion: 159 do
    scenario "evaluate passes when two personas are linked plus a rule with happy + failure scenarios" do
      given_ :persona_exists

      given_ "a second persona is created and linked to the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:ok, create_response} =
          ToolLibrary.run(
            "create_persona",
            %{
              slug: "driver",
              name: "Driver",
              headline: "Fleet driver attempting card transactions"
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        driver_id = extract_persona_id(create_response)

        {:ok, _link_response} =
          ToolLibrary.run(
            "link_persona_to_story",
            %{persona_id: driver_id, story_number: context.story.number},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, context}
      end

      given_ "one rule exists with happy + failure scenarios", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        rule_statement = "Suspended cards cannot be used for purchases"

        _add_rule =
          ToolLibrary.run(
            "add_rule",
            %{story_number: context.story.number, statement: rule_statement},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        _happy =
          ToolLibrary.run(
            "add_scenario",
            %{
              story_number: context.story.number,
              rule_statement: rule_statement,
              title: "Driver attempts purchase with suspended card",
              kind: "happy_path",
              body: "Given context\nWhen action\nThen happy outcome"
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        _failure =
          ToolLibrary.run(
            "add_scenario",
            %{
              story_number: context.story.number,
              rule_statement: rule_statement,
              title: "Suspension status fails to load",
              kind: "failure_path",
              body: "Given context\nWhen action\nThen failure outcome"
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, context}
      end

      given_ :three_amigos_task_started

      when_ "the agent calls evaluate_task on the Three Amigos task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.task_id, session_id: context.session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
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

  defp extract_persona_id(response),
    do: extract_persona_id_from(Regex.run(~r/\bid: `([^`]+)`/, response_text(response)), response)

  defp extract_persona_id_from([_, id], _response), do: id

  defp extract_persona_id_from(_, response),
    do: raise("Could not extract persona id from response: #{inspect(response)}")
end
