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
    scenario "Postgres fails its prerequisite check on Sam's laptop" do
      given_ "Postgres fails its prerequisite check on Sam's laptop", context do
        CodeMySpecSpex.Fixtures.without_setup_postgres(context)
        {:ok, context}
      end

      when_ "setup runs", context do
        {:ok, snapshot} = CodeMySpecSpex.Fixtures.check_machine_prerequisites()
        {:ok, Map.put(context, :snapshot, snapshot)}
      end

      then_ "it says the Postgres step failed and why", context do
        step = Enum.find(context.snapshot["steps"], &(&1["key"] == "postgres"))
        assert step["state"] == "errored"
        assert step["error"] =~ "psql"

        {:ok, context}
      end

      then_ "the box is not shown as ready", context do
        refute CodeMySpecSpex.Fixtures.machine_prerequisites_passed?(context.snapshot)
        {:ok, context}
      end
    end
  end
end
