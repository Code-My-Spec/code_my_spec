defmodule CodeMySpecSpex.Story1086.Criterion1766Spex do
  @moduledoc """
  Story 1086 — I see every change made to my project's setup
  Criterion 1766 — Sam filters Activity to prod.

  Unfiltered, a project with two busy environments reads as one long list
  with no way to ask "did anything happen to prod" without reading past
  every uat entry first. The filter is a query parameter
  (`?activity_env=`), not a second page — so filtering never costs a
  reload of state the page already has.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Sam filters Activity to prod", criterion: 1766 do
    scenario "one entry each on uat and prod, filtered to prod alone" do
      given_ "an entry on uat and an entry on prod", context do
        CodeMySpec.Activity.record(context.scope, "provision", "servers", "ran the server step",
          environment: "uat"
        )

        CodeMySpec.Activity.record(context.scope, "provision", "servers", "ran the server step",
          environment: "prod"
        )

        {:ok, context}
      end

      when_ "Sam filters Activity to prod", context do
        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/activity?activity_env=prod"
          )

        {:ok, Map.put(context, :document, Floki.parse_document!(render(view)))}
      end

      then_ "only prod's entry shows", context do
        entries = Floki.find(context.document, "[data-test='activity-entry']")

        assert Floki.attribute(entries, "data-environment") == ["prod"],
               "expected only prod's entry, got #{inspect(Floki.attribute(entries, "data-environment"))}"

        {:ok, context}
      end

      then_ "and the filter itself shows which one is active", context do
        active = Floki.find(context.document, "[data-test='activity-filter-option'].tab-active")

        assert Floki.attribute(active, "data-environment") == ["prod"],
               "the filter control doesn't show prod as the active choice"

        {:ok, context}
      end
    end
  end
end
