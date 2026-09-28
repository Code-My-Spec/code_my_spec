defmodule CodeMySpecSpex.Story1076.Criterion4696Spex do
  @moduledoc """
  Story 1076 — Criteria are added, reworded and retired, never deleted
  Criterion 4696 — Migrated criteria arrive with their numbers and retired state.

  Covers Rule "A criterion keeps its number when the project moves to the
  cloud".

  Surface: `POST /api/migrations`, then the agent's own reads on the cloud.
  Local ids are rewritten as the graph lands; the number is not, because the
  specs on Sam's disk name it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :paid_account

  defp paid_account(context), do: {:ok, Map.put(context, :scope, Fixtures.paid(context.scope))}

  spex "Criterion numbers survive the move to the cloud", criterion: 1572 do
    scenario "an active and a retired criterion arrive as they left" do
      given_ "a local project with active criterion 12 and retired criterion 14", context do
        payload =
          Fixtures.migration_payload(
            stories: [
              %{
                local_id: 1,
                title: "Ship the thing",
                story: "As Sam, I want to ship so that it ships."
              }
            ],
            criteria: [
              %{local_id: "c12", story_local_id: 1, number: 12, description: "It ships once"},
              %{
                local_id: "c14",
                story_local_id: 1,
                number: 14,
                description: "It ships on Fridays",
                retired_at: "2026-09-01T00:00:00Z"
              }
            ]
          )

        {:ok, Map.put(context, :payload, payload)}
      end

      when_ "Sam migrates it to the cloud", context do
        response = Fixtures.migrate(context.scope, context.payload)
        assert response.status == 200, "the migration must succeed first"
        {:ok, context}
      end

      then_ "the cloud project has active criterion 12", context do
        story = Fixtures.cloud_story(context.scope, "Ship the thing")
        text = CriterionScript.story_text(context.scope, story.number)

        assert CriterionScript.numbers(text) == [12],
               "expected criterion 12 active on the cloud, and 14 not among the active. get_story showed:\n#{text}"

        {:ok, context}
      end

      and_ "retired criterion 14", context do
        result =
          CriterionScript.run(context.scope, """
          return get_criterion({ criterion_number = 14 })
          """)

        refute result.error?, "criterion 14 should be readable on the cloud. Got: #{result.text}"
        assert result.text =~ "It ships on Fridays"

        assert result.text =~ ~r/retired/i,
               "criterion 14 should arrive retired. Got: #{result.text}"

        {:ok, context}
      end
    end
  end
end
