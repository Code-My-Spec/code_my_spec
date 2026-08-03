defmodule CodeMySpecSpex.Story991.Criterion8230Spex do
  @moduledoc """
  Story 991 — Criterion 8230 — Migrating one project leaves his others alone.

  Covers Rule "Sam migrates one project at a time."

  Sam's local harness holds every project he has — on the machine this was
  written on, seventeen of them, including client work. Migrating one because
  he upgraded must not send the others anywhere, which is the argument that
  settled the design: a whole-database copy would have been simpler and would
  have shipped sixteen projects nobody asked to move.

  The export is scoped by reading only the active project, so this is a
  property of what it looks at rather than of what it filters out afterwards.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "One project moves, the rest stay" do
    scenario "Migrating one project leaves his others alone" do
      given_ "Sam has two projects with a story each", context do
        scope = Fixtures.paid(context.scope)
        Fixtures.authored_story(scope, "Belongs to the migrating project")

        other = CodeMySpec.ProjectsFixtures.project_fixture(scope, %{name: "Sam's other project"})
        other_scope = %{scope | active_project: other, active_project_id: other.id}
        Fixtures.authored_story(other_scope, "Belongs to the other project")

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:other_scope, other_scope)}
      end

      when_ "he migrates one of them", context do
        payload = Fixtures.exported(context.scope)

        refute Enum.any?(payload["stories"], &(&1["title"] == "Belongs to the other project")),
               "the export must not even read the other project, let alone send it"

        assert Fixtures.migrate(context.scope, payload).status == 200

        {:ok, context}
      end

      then_ "only that project's work is on the cloud", context do
        titles = context.scope |> Fixtures.cloud_stories() |> Enum.map(& &1.title)

        assert "Belongs to the migrating project" in titles
        refute "Belongs to the other project" in titles

        {:ok, context}
      end

      and_ "the other project is untouched locally", context do
        titles = context.other_scope |> Fixtures.cloud_stories() |> Enum.map(& &1.title)

        assert "Belongs to the other project" in titles,
               "the project he did not migrate keeps its work exactly where it was"

        {:ok, context}
      end
    end
  end
end
