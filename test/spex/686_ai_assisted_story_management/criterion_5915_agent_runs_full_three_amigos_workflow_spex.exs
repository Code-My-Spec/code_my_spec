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
  alias CodeMySpec.McpServers.BddRules.Tools.AddQuestion
  alias CodeMySpec.McpServers.BddRules.Tools.AddRule
  alias CodeMySpec.McpServers.BddRules.Tools.AddScenario
  alias CodeMySpec.McpServers.BddRules.Tools.GetStoryGherkin
  alias CodeMySpec.McpServers.BddRules.Tools.ListQuestions
  alias CodeMySpec.McpServers.BddRules.Tools.ListRules
  alias CodeMySpec.McpServers.Personas.Tools.CreatePersona
  alias CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory
  alias CodeMySpecSpex.StoryHelpers

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent runs a full Three Amigos workflow through the PM server tools" do
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

        {:reply, persona_response, _frame} =
          CreatePersona.execute(
            %{
              name: "Workshop Persona",
              slug: "workshop-persona-#{System.unique_integer([:positive])}",
              description: "Persona used to satisfy linkage."
            },
            frame
          )

        persona_id = extract_persona_id(persona_response)

        {:reply, _, _frame} =
          LinkPersonaToStory.execute(
            %{story_id: story.id, persona_id: persona_id},
            frame
          )

        rule_statement = "Drivers must have a verified phone number."

        {:reply, _, _frame} =
          AddRule.execute(%{story_id: story.id, statement: rule_statement}, frame)

        {:reply, _, _frame} =
          AddScenario.execute(
            %{
              story_id: story.id,
              rule_statement: rule_statement,
              title: "Driver finishes verification, account is activated",
              kind: "happy_path",
              body: """
              Given a driver has entered a phone number
              When the driver enters the SMS code
              Then the account is marked verified
              """
            },
            frame
          )

        {:ok, Map.merge(context, %{story: story, rule_statement: rule_statement})}
      end

      when_ "the agent parks a question on the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AddQuestion.execute(
            %{
              story_id: context.story.id,
              text: "Does verification time out after 24 hours?"
            },
            frame
          )

        refute response.isError,
               "expected add_question to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :question_response, response)}
      end

      then_ "list_rules returns the rule statement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListRules.execute(%{story_id: context.story.id}, frame)

        body = response_text(response)

        assert body =~ context.rule_statement,
               "expected rule visible in list_rules, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "list_questions returns the parked question", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListQuestions.execute(%{story_id: context.story.id}, frame)

        body = response_text(response)

        assert body =~ "Does verification time out",
               "expected question visible in list_questions, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "get_story_gherkin renders the rule and scenario body", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          GetStoryGherkin.execute(%{story_id: context.story.id}, frame)

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
