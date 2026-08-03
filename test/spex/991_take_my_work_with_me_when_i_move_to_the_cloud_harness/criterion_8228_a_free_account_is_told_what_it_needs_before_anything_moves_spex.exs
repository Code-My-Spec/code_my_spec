defmodule CodeMySpecSpex.Story991.Criterion8228Spex do
  @moduledoc """
  Story 991 — Criterion 8228 — A free account is told what it needs before
  anything moves.

  Covers Rule "Migration requires an account already on a paid plan."

  Migration is how Sam upgrades, but it is not where he buys. Keeping billing
  out of this path means the refusal has to be legible on its own: a person who
  has just tried to move a year of work needs to read "you need a plan", not a
  validation error that leaves him wondering whether his data is malformed.

  Checked before the transaction opens, so a refused migration writes nothing
  at all — there is no partial project to explain afterwards.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A plan is required before anything moves" do
    scenario "A free account is told what it needs before anything moves" do
      given_ "Sam's account is not on a paid plan", context do
        assert context.scope.active_account.plan == :free,
               "a new account starts free — that is the state this is about"

        Fixtures.authored_story(context.scope, "Work he has not paid to move yet")
        cloud = Fixtures.other_project_scope(context.scope, "Cloud target")

        {:ok, context |> Map.put(:cloud, cloud)}
      end

      when_ "he tries to migrate a project", context do
        response = Fixtures.migrate(context.cloud, Fixtures.exported(context.scope))

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the migration refuses before copying anything", context do
        assert context.response.status == 422

        assert Fixtures.cloud_stories(context.cloud) == [],
               "a refusal has to leave the target empty, not partly written"

        {:ok, context}
      end

      and_ "it tells him a plan is what is missing", context do
        reason = context.response.resp_body |> Jason.decode!() |> Map.get("reason")

        assert reason =~ "plan",
               """
               "something went wrong" sends Sam to check his data. Naming the
               plan sends him to the place that fixes it, which is the whole
               difference between a refusal and a failure.

               got: #{reason}
               """

        {:ok, context}
      end
    end
  end
end
