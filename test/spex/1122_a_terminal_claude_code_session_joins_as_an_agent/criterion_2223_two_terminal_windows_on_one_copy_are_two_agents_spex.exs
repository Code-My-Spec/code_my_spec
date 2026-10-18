defmodule CodeMySpecSpex.Story1122.Criterion2223Spex do
  @moduledoc """
  Story 1122 — A terminal Claude Code session joins as an agent.
  Criterion 2223 — Two terminal windows on one copy are two agents.
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

  spex "Two terminal windows on one copy are two agents", criterion: 2223 do
    scenario "a developer opens two terminal windows on the same working copy" do
      given_ "a developer's checkout of the project, served by its harness", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      when_ "a Claude Code session starts in each window", context do
        {:ok,
         Map.merge(context, %{
           one: start_session(context, session_id()),
           two: start_session(context, session_id())
         })}
      end

      then_ "two agents are registered on that copy, one per session", context do
        refute context.one["agent_id"] == context.two["agent_id"]

        assert [_, _] = rows = agents(context)
        assert Enum.all?(rows, &(&1["working_copy"] == context.harness.root))
        {:ok, context}
      end
    end
  end
end
