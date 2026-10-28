defmodule CodeMySpecSpex.Story1171.Criterion2542Spex do
  @moduledoc """
  Story 1171 — I am told when work goes into the queue and never comes out.
  Criterion 2542 — A stuck entry is reported once, not on every check.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A stuck promotion entry is reported once per reporting interval", criterion: 2542 do
    scenario "two checks within the interval are silent; the next interval permits a reminder" do
      given_ "a promotion entry has already been reported stuck to Main", context do
        entry = Fixtures.stuck_promotion_entry(context.scope)
        :ok = Fixtures.configure_stuck_work(context.scope, reporting_interval_minutes: 10)
        :ok = Fixtures.record_stuck_notification(context.scope, entry.id)
        {:ok, Map.put(context, :entry_id, entry.id)}
      end

      when_ "the entry is checked twice within the interval and again afterward", context do
        tool_context = %{scope: context.scope, current_scope: context.scope}
        {:ok, _} = ToolLibrary.run("get_stuck_work", %{}, tool_context)
        :ok = Fixtures.advance_stuck_clock(context.scope, minutes: 5)
        {:ok, _} = ToolLibrary.run("get_stuck_work", %{}, tool_context)
        within_interval = Fixtures.main_stuck_notifications(context.scope, context.entry_id)
        :ok = Fixtures.advance_stuck_clock(context.scope, minutes: 6)
        {:ok, _} = ToolLibrary.run("get_stuck_work", %{}, tool_context)
        {:ok, Map.put(context, :within_interval, within_interval)}
      end

      then_ "Main has one report within the interval and one reminder afterward", context do
        assert length(context.within_interval) == 1
        assert length(Fixtures.main_stuck_notifications(context.scope, context.entry_id)) == 2
        {:ok, context}
      end
    end
  end
end
