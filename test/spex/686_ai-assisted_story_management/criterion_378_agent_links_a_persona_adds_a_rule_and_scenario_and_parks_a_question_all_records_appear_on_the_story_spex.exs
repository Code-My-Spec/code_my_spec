defmodule CodeMySpecSpex.Story686.Criterion5915Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 5915 — Agent links a persona, adds a rule and scenario, and
  parks a question — all records appear on the story.

  This spec asserts the *composite* surface: the agent can drive a full
  Three Amigos workshop using tools reachable from the PM (stories) MCP
  server, without crossing into a separate server. The discrete tool
  behaviors are exercised by the 559 (Three Amigos) and 685 (Story
  tagging) spex suites; this scenario binds them together end-to-end.

  Surface: `link_persona_to_story`, `add_rule`, `add_scenario`,
  `add_question`, `list_questions`, `list_rules`, `get_story_gherkin`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent runs a full Three Amigos workflow through the PM server tools", criterion: 378 do
    scenario "Persona, rule, scenario, and question all persist on the story" do
      given_ "a story exists with a linked persona and a rule", context do
        scope = context.scope
        frame = %Frame{assigns: %{current_scope: scope}}

        story =
          StoryHelpers.create_story(scope,
            title: "Workshop story",
            description: "Hosts the full Three Amigos sequence.",
            acceptance_criteria: []
          )

        {:ok, persona_response} =
          ToolLibrary.run(
            "create_persona",
            %{
              name: "Workshop Persona",
              slug: "workshop-persona-#{System.unique_integer([:positive])}",
              description: "Persona used to satisfy linkage."
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        persona_id = extract_persona_id(persona_response)

        {:ok, _} =
          ToolLibrary.run(
            "link_persona_to_story",
            %{story_number: story.number, persona_id: persona_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        rule_statement = "Drivers must have a verified phone number."

        _ =
          ToolLibrary.run("add_rule", %{story_number: story.number, statement: rule_statement}, %{
            scope: frame.assigns.current_scope
          })

        _ =
          ToolLibrary.run(
            "add_scenario",
            %{
              story_number: story.number,
              rule_statement: rule_statement,
              title: "Driver finishes verification, account is activated",
              kind: "happy_path",
              body: """
              Given a driver has entered a phone number
              When the driver enters the SMS code
              Then the account is marked verified
              """
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.merge(context, %{story: story, rule_statement: rule_statement})}
      end

      when_ "the agent parks a question on the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "add_question",
            %{
              story_number: context.story.number,
              text: "Does verification time out after 24 hours?"
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response),
               "expected add_question to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :question_response, response)}
      end

      then_ "list_rules returns the rule statement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run("list_rules", %{story_number: context.story.number}, %{
            scope: frame.assigns.current_scope
          })

        body = response_text(response)

        assert body =~ context.rule_statement,
               "expected rule visible in list_rules, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "list_questions returns the parked question", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run("list_questions", %{story_number: context.story.number}, %{
            scope: frame.assigns.current_scope
          })

        body = response_text(response)

        assert body =~ "Does verification time out",
               "expected question visible in list_questions, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "get_story_gherkin renders the rule and scenario body", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run("get_story_gherkin", %{story_number: context.story.number}, %{
            scope: frame.assigns.current_scope
          })

        body = response_text(response)

        assert body =~ context.rule_statement,
               "expected rule in gherkin output, got: #{inspect(body)}"

        assert body =~ "the account is marked verified",
               "expected scenario body in gherkin output, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end

  defp extract_persona_id(response) do
    [_, id] = Regex.run(~r/id:\s*`([^`]+)`/, response_text(response))
    id
  end
end
