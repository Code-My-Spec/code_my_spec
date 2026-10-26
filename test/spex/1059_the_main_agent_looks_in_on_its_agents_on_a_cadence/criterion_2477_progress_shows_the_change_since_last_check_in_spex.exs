defmodule CodeMySpecSpex.Story1059.Criterion2477Spex do
  @moduledoc """
  Story 1059 — The main agent looks in on its agents on a cadence.
  Criterion 2477 — Requirement progress shows the change since the previous
  check-in.

  "2741/2858 satisfied" read on its own says nothing about whether the last
  half hour moved anything. Comparing it with the previous check-in by hand is
  the work the line should have done.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.CompactCadenceHelpers, as: Compact
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The second check-in says what changed since the first", criterion: 2477 do
    scenario "main checks in twice" do
      given_ "main has already checked in once", context do
        context = context |> Compact.fleet(1) |> Compact.report()
        {:ok, Map.put(context, :first, context.report)}
      end

      when_ "it checks in again", context do
        {:ok, Compact.report(context)}
      end

      then_ "the first had no comparison to make", context do
        refute context.first =~ "since last check-in",
               "The first check-in has nothing to compare with.\n\n#{context.first}"

        {:ok, context}
      end

      then_ "and the second reports the change since the first", context do
        assert context.report =~ ~r/Requirements: \d+\/\d+ satisfied \([^)]*since last check-in\)/,
               """
               The requirement line should say how it moved since the previous
               check-in, even when the answer is that it did not.

               #{context.report}
               """

        {:ok, context}
      end
    end
  end
end
