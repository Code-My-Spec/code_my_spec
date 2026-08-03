defmodule CodeMySpecSpex.Story991.Criterion8222Spex do
  @moduledoc """
  Story 991 — Take my work with me when I move to the cloud harness.
  Criterion 8222 — Sam's stories and their scenarios arrive intact.

  Covers Rule "Only what Sam authored moves; anything the harness can
  recompute is left to rebuild."

  Surface: `POST /api/migrations` on the server, carrying one project's
  authored graph in one request.

  "Intact" is the whole assertion, and it is about the edges rather than the
  counts. Ninety stories and eight hundred criteria arriving as ninety stories
  and eight hundred criteria proves nothing if a scenario has been reattached
  to the wrong rule — Sam would find a Three Amigos session that reads as
  nonsense and no error anywhere to explain it.

  Local ids are integers the cloud does not use, so every reference has to be
  rewritten as the graph lands. That remapping is the only hard part of this
  story, and this is where it is proved.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :paid_account

  # Story 991 requires an account already on a plan; migrating is not how Sam
  # buys one. Criterion 8228 is the spec for what happens without it.
  defp paid_account(context), do: {:ok, Map.put(context, :scope, Fixtures.paid(context.scope))}

  spex "An authored project arrives whole" do
    scenario "Sam's stories and their scenarios arrive intact" do
      given_ "Sam has a story with a persona, a rule and two scenarios locally", context do
        payload =
          Fixtures.migration_payload(
            stories: [
              %{
                local_id: 1,
                title: "Ship the thing",
                story: "As Sam, I want to ship the thing so that it is shipped."
              }
            ],
            rules: [%{local_id: "r1", story_local_id: 1, statement: "It ships once."}],
            personas: [%{local_id: "p1", name: "Solo Shipper Sam", slug: "solo-shipper-sam"}],
            persona_stories: [%{persona_local_id: "p1", story_local_id: 1}],
            criteria: [
              %{
                local_id: "c1",
                story_local_id: 1,
                rule_local_id: "r1",
                description: "shipping twice is refused"
              },
              %{
                local_id: "c2",
                story_local_id: 1,
                rule_local_id: "r1",
                description: "a shipped thing stays shipped"
              }
            ]
          )

        {:ok, Map.put(context, :payload, payload)}
      end

      when_ "he migrates the project to the cloud", context do
        response = Fixtures.migrate(context.scope, context.payload)

        assert response.status == 200,
               "the migration must succeed before anything about its contents is worth asking"

        {:ok, context}
      end

      then_ "the story is on the cloud project", context do
        assert Enum.any?(Fixtures.cloud_stories(context.scope), &(&1.title == "Ship the thing")),
               "expected Sam's story on the cloud project"

        {:ok, context}
      end

      and_ "each scenario is still attached to the rule it illustrated", context do
        story = Fixtures.cloud_story(context.scope, "Ship the thing")
        rule = Fixtures.cloud_rule(context.scope, story, "It ships once.")

        descriptions =
          context.scope
          |> Fixtures.cloud_criteria(story)
          |> Enum.filter(&(&1.rule_id == rule.id))
          |> Enum.map(& &1.description)
          |> Enum.sort()

        assert descriptions == ["a shipped thing stays shipped", "shipping twice is refused"],
               """
               Both scenarios have to come back under the rule they were written
               for. Local ids are integers the cloud does not use, so every
               reference is rewritten as the graph lands — and a scenario
               reattached to the wrong rule produces a Three Amigos session that
               reads as nonsense with no error to explain it.
               """

        {:ok, context}
      end
    end
  end
end
