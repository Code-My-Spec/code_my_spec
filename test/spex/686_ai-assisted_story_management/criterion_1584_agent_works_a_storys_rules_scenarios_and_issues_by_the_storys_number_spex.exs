defmodule CodeMySpecSpex.Story686.Criterion1584Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 1584 — Agent works a story's rules, scenarios and issues by the
  story's number.

  Covers Rule "Stories are named by their number and criteria by their number,
  everywhere." The Three Amigos and issue tools hang work off a story, and they
  take the same number the story tools do.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.CriterionScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Rules, scenarios and issues are attached by story number", criterion: 1584 do
    scenario "the agent maps a story and files an issue against it" do
      given_ "story A exists", context do
        story = CriterionScript.create_story(context.scope, "Story A", [])
        {:ok, Map.put(context, :story, story)}
      end

      when_ "the agent adds a rule and scenario and files an issue, all by story A's number",
            context do
        result =
          CriterionScript.run(context.scope, """
          local persona = create_persona({ slug = "owner", name = "Owner" })
          local persona_id = persona:match("id: `([%w%-]+)`")
          link_persona_to_story({ persona_id = persona_id, story_number = #{context.story} })
          add_rule({ story_number = #{context.story}, statement = "Bookings need a customer." })
          add_scenario({
            story_number = #{context.story},
            rule_statement = "Bookings need a customer.",
            title = "A booking without a customer is refused",
            kind = "happy_path",
            body = "Given no customer\\nWhen I book\\nThen it is refused"
          })
          local issue = create_issue({
            title = "Booking form is unclear",
            severity = "low",
            description = "Seen in QA.",
            story_number = #{context.story}
          })
          return issue:match("ID: ([%w%-]+)")
          """)

        refute result.error?, "the calls failed: #{result.text}"
        [_, issue_id] = Regex.run(~r/Returned:\s*"?([0-9a-f-]{36})/, result.text)

        {:ok, Map.put(context, :issue_id, issue_id)}
      end

      then_ "story A's rules and scenario read back by its number", context do
        text =
          CriterionScript.run(
            context.scope,
            "return get_story_gherkin({ story_number = #{context.story} })"
          ).text

        assert text =~ "Bookings need a customer.", text
        assert text =~ "A booking without a customer is refused", text

        {:ok, context}
      end

      and_ "the issue names story A by its number", context do
        text =
          CriterionScript.run(
            context.scope,
            "return get_issue({ issue_id = \"#{context.issue_id}\" })"
          ).text

        assert text =~ "**Story:** #{context.story}", text

        {:ok, context}
      end
    end
  end
end
