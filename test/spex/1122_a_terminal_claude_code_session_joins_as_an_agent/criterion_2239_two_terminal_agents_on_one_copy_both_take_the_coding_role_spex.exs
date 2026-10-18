defmodule CodeMySpecSpex.Story1122.Criterion2239Spex do
  @moduledoc """
  Story 1122 — A terminal Claude Code session joins as an agent.
  Criterion 2239 — Two terminal agents on one copy both take the coding role.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers

  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Two terminal agents on one copy both take the coding role", criterion: 2239 do
    scenario "two terminal sessions on one copy both choose coding" do
      given_ "two terminal agents on the same working copy", context do
        context = HarnessHooks.ensure_live_harness(context)
        one = session_id()
        two = session_id()
        start_session(context, one)
        start_session(context, two)
        {:ok, Map.merge(context, %{one: one, two: two})}
      end

      when_ "both take the coding role", context do
        {:ok,
         Map.put(context, :set, [
           set_role(context, context.one, "coding"),
           set_role(context, context.two, "coding")
         ])}
      end

      then_ "both hold it", context do
        assert [{:ok, _}, {:ok, _}] = context.set
        assert [%{"role" => "coding"}, %{"role" => "coding"}] = agents(context)
        {:ok, context}
      end
    end
  end
end
