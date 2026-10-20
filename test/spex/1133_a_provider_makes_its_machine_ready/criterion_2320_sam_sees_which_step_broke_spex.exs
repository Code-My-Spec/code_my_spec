defmodule CodeMySpecSpex.Story1133.Criterion2320Spex do
  @moduledoc """
  Story 1133 — A provider makes its machine ready.
  Criterion 2320 — Sam sees which step broke.

  Mirrors story 1112's criterion 2036 (a missing pgvector blocks project
  creation with an explanation), but for the Postgres step itself: this
  writes a fake `psql` that fails only on the `--version` check `Prerequisites`
  runs for the `postgres` key, leaving the `pgvector` check (a different
  `psql` invocation) alone so the one failure is unambiguous.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpecSpex.DesktopSetupHelpers

  setup :fresh_machine
  defp fresh_machine(context), do: DesktopSetupHelpers.fresh_machine(context)

  spex "A failed step says which one and why, and the box is not ready", criterion: 2320 do
    scenario "Postgres fails to install on Sam's laptop" do
      given_ "Postgres fails to install on Sam's laptop", context do
        DesktopSetupHelpers.without_postgres(context)
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      when_ "setup runs", context do
        context.view |> element("[data-test='check-prerequisites']") |> render_click()
        render_async(context.view, 10_000)
        {:ok, context}
      end

      then_ "it says the Postgres step failed and why", context do
        assert has_element?(
                 context.view,
                 "[data-test='prerequisite'][data-name='postgres'][data-state='failed']"
               )

        assert has_element?(
                 context.view,
                 "[data-name='postgres'] [data-test='install-instructions']",
                 "psql"
               )

        {:ok, context}
      end

      then_ "the box is not shown as ready", context do
        refute has_element?(context.view, "[data-test='create-project']:not([disabled])")
        refute has_element?(context.view, "[data-test='project-connected']")
        {:ok, context}
      end
    end
  end
end
