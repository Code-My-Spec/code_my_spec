defmodule CodeMySpecSpex.Story991.Criterion8226Spex do
  @moduledoc """
  Story 991 — Criterion 8226 — Running the migration again adopts the existing
  project.

  Covers Rule "Migrating the same project twice does not produce two of it."

  Sam will run this twice. A migration is the kind of thing you re-run when you
  are not sure it worked the first time — which is exactly when duplicating
  ninety stories does the most damage, because now he cannot tell the copies
  apart to clean up.

  Idempotence here is by natural key, not by remembering what was written. The
  second run has no memory of the first, so the question it can answer is "is
  this story already here", not "did I write this before". A title within a
  project is the identity Sam would use himself.
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

  spex "Migrating twice is safe" do
    scenario "Running the migration again adopts the existing project" do
      given_ "Sam has already migrated a project", context do
        payload =
          Fixtures.migration_payload(
            stories: [
              %{local_id: 1, title: "Only once", story: "As Sam, I want one, so that reasons."}
            ],
            personas: [%{local_id: "p1", name: "Sam", slug: "sam-991-8226"}],
            persona_stories: [%{persona_local_id: "p1", story_local_id: 1}],
            rules: [%{local_id: "r1", story_local_id: 1, statement: "It happens once."}],
            criteria: [
              %{
                local_id: "c1",
                story_local_id: 1,
                rule_local_id: "r1",
                description: "just the one"
              }
            ]
          )

        assert Fixtures.migrate(context.scope, payload).status == 200

        {:ok, Map.put(context, :payload, payload)}
      end

      when_ "he runs the migration for that project again", context do
        response = Fixtures.migrate(context.scope, context.payload)

        assert response.status == 200,
               "a second run is not an error — it is a person checking their work. " <>
                 "got #{response.status}: #{response.resp_body}"

        {:ok, context}
      end

      then_ "the cloud still holds one copy of it", context do
        titles = context.scope |> Fixtures.cloud_stories() |> Enum.map(& &1.title)

        assert Enum.count(titles, &(&1 == "Only once")) == 1,
               "expected one story, got #{inspect(titles)}"

        {:ok, context}
      end

      and_ "nothing he authored is duplicated", context do
        story = Fixtures.cloud_story(context.scope, "Only once")
        criteria = Fixtures.cloud_criteria(context.scope, story)

        assert Enum.count(criteria, &(&1.description == "just the one")) == 1,
               """
               Scenarios duplicate as readily as stories, and are harder to
               spot: Sam opens Three Amigos and sees each scenario twice with
               nothing saying why.
               """

        {:ok, context}
      end
    end
  end
end
