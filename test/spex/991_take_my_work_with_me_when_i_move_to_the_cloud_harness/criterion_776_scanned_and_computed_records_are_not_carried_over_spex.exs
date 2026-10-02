defmodule CodeMySpecSpex.Story991.Criterion8223Spex do
  @moduledoc """
  Story 991 — Criterion 8223 — Scanned and computed records are not carried over.

  Covers Rule "Only what Sam authored moves; anything the harness can recompute
  is left to rebuild."

  This is most of the local database by volume. A project holds ~4,500 file
  records, plus problems and sessions — none of it authored. Files come from
  scanning a working copy, problems from analysers. Copying them would make the
  payload far larger to deliver a snapshot that goes stale the moment Sam's
  next sync runs.

  Components used to be in this list, as projections of spec files. Since they
  became records (3aeb66cf, step 6) they are authored and travel.

  The migration says what it left behind rather than staying quiet about it, so
  a short summary is not mistaken for a partial one.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :paid_account

  # Story 991 requires an account already on a plan; migrating is not how Sam
  # buys one. Criterion 8228 is the spec for what happens without it.
  defp paid_account(context), do: {:ok, Map.put(context, :scope, Fixtures.paid(context.scope))}

  spex "Derived records stay behind", criterion: 776 do
    scenario "Scanned and computed records are not carried over" do
      when_ "Sam migrates a project", context do
        payload =
          Fixtures.migration_payload(
            stories: [
              %{local_id: 1, title: "A story", story: "As Sam, I want a thing, so that reasons."}
            ]
          )

        response = Fixtures.migrate(context.scope, payload)
        assert response.status == 200

        {:ok, Map.put(context, :body, Jason.decode!(response.resp_body))}
      end

      then_ "no file, problem or session records come with it", context do
        skipped = context.body["migrated"]["skipped"]

        for kind <- ~w(files problems sessions requirements) do
          assert kind in skipped,
                 "expected #{kind} to be named as left behind, not silently omitted"
        end

        {:ok, context}
      end

      and_ "the harness agrees about which kinds it recomputes", context do
        assert "files" in Fixtures.derived_kinds()
        refute "components" in Fixtures.derived_kinds(), "components are authored records now"

        refute "stories" in Fixtures.derived_kinds(),
               "a story is authored — if this ever reads as derived, Sam's work is being dropped"

        {:ok, context}
      end
    end
  end
end
