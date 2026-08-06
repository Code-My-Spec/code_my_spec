defmodule CodeMySpecSpex.Story991.Criterion8231Spex do
  @moduledoc """
  Story 991 — Criterion 8231 — A failure part-way leaves nothing behind on the
  cloud.

  Covers Rule "A migration either lands completely or not at all."

  This is the rule that decided the shape of the whole feature. Per-entity CRUD
  would have meant ~1,500 requests, any one of which could be the last — and a
  project half on the cloud is worse than one not there at all, because Sam has
  to work out what arrived before he dares retry.

  Driven by a payload whose later records are unusable: the story is fine, the
  scenario points at a story that was never sent. The failure lands after real
  writes have happened, which is the only arrangement that proves the rollback
  rather than the validation.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :paid_account

  # Story 991 requires an account already on a plan; migrating is not how Sam
  # buys one. Criterion 8228 is the spec for what happens without it.
  defp paid_account(context), do: {:ok, Map.put(context, :scope, Fixtures.paid(context.scope))}

  spex "A migration lands whole or not at all" do
    scenario "A failure part-way leaves nothing behind on the cloud" do
      given_ "the cloud project has no stories yet", context do
        assert Fixtures.cloud_stories(context.scope) == [],
               "the scenario proves nothing if something was already there"

        {:ok, context}
      end

      when_ "a migration fails after some records have been written", context do
        payload =
          Fixtures.migration_payload(
            stories: [
              %{local_id: 1, title: "Written first", story: "As Sam, I want it, so that reasons."}
            ],
            criteria: [
              %{local_id: "c1", story_local_id: 99, description: "points at a story never sent"}
            ]
          )

        response = Fixtures.migrate(context.scope, payload)

        assert response.status == 422,
               "a payload referencing a story that was never sent has to be refused"

        {:ok, context}
      end

      then_ "the story written before the failure is not on the cloud", context do
        assert Fixtures.cloud_stories(context.scope) == [],
               """
               The story was inserted before the criterion failed. If it
               survives, Sam has a project holding part of his work and no way
               to tell which part — and retrying would double whatever did
               arrive.
               """

        {:ok, context}
      end

      and_ "he is told what could not be placed", context do
        payload =
          Fixtures.migration_payload(
            criteria: [%{local_id: "c1", story_local_id: 99, description: "orphan"}]
          )

        body =
          context.scope |> Fixtures.migrate(payload) |> Map.get(:resp_body) |> Jason.decode!()

        assert body["reason"] =~ "99",
               "naming the record that could not be placed is what makes the failure actionable"

        {:ok, context}
      end
    end
  end
end
