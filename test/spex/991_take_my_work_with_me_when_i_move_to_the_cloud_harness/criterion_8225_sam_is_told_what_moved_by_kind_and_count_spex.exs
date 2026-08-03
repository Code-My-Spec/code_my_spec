defmodule CodeMySpecSpex.Story991.Criterion8225Spex do
  @moduledoc """
  Story 991 — Criterion 8225 — Sam is told what moved, by kind and count.

  Covers Rule "Sam can see what arrived before he trusts it."

  A migration that says only "done" asks Sam to take its word. He has just moved
  years of work onto someone else's machine on the strength of an upgrade, and
  the reasonable next question is how much of it arrived. Counts per kind are
  the cheapest possible answer and they let him check against what he knows he
  had.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :paid_account

  # Story 991 requires an account already on a plan; migrating is not how Sam
  # buys one. Criterion 8228 is the spec for what happens without it.
  defp paid_account(context) do
    {:ok, account} =
      CodeMySpec.Accounts.update_account(context.scope, context.scope.active_account, %{
        plan: :paid
      })

    {:ok, Map.put(context, :scope, %{context.scope | active_account: account})}
  end

  spex "The migration reports what it moved" do
    scenario "Sam is told what moved, by kind and count" do
      when_ "Sam migrates a project with two stories and three scenarios", context do
        payload =
          Fixtures.migration_payload(
            stories: [
              %{local_id: 1, title: "First", story: "As Sam, I want one, so that reasons."},
              %{local_id: 2, title: "Second", story: "As Sam, I want two, so that reasons."}
            ],
            personas: [%{local_id: "p1", name: "Sam", slug: "sam-991-8225"}],
            persona_stories: [
              %{persona_local_id: "p1", story_local_id: 1},
              %{persona_local_id: "p1", story_local_id: 2}
            ],
            rules: [%{local_id: "r1", story_local_id: 1, statement: "It holds."}],
            criteria: [
              %{local_id: "c1", story_local_id: 1, rule_local_id: "r1", description: "one"},
              %{local_id: "c2", story_local_id: 1, rule_local_id: "r1", description: "two"},
              %{local_id: "c3", story_local_id: 2, description: "three"}
            ]
          )

        response = Fixtures.migrate(context.scope, payload)
        assert response.status == 200

        {:ok, Map.put(context, :migrated, Jason.decode!(response.resp_body)["migrated"])}
      end

      then_ "the report names how many of each kind arrived", context do
        assert context.migrated["stories"] == 2
        assert context.migrated["criteria"] == 3
        assert context.migrated["rules"] == 1
        assert context.migrated["personas"] == 1

        {:ok, context}
      end
    end
  end
end
