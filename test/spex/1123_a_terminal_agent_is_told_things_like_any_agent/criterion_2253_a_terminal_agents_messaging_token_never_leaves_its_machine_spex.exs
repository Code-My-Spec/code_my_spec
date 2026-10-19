defmodule CodeMySpecSpex.Story1123.Criterion2253Spex do
  @moduledoc """
  Story 1123 — A terminal agent is told things like any agent.
  Criterion 2253 — A terminal agent's messaging token never leaves its machine.
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

  spex "A terminal agent's messaging token never leaves its machine", criterion: 2253 do
    scenario "a session registers through its harness" do
      given_ "a developer's checkout of the project, served by its harness", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      when_ "a session starts on it", context do
        {:ok, Map.put(context, :started, start_session(context, session_id()))}
      end

      then_ "nothing the server holds or answers carries a messaging token or socket", context do
        listing = Jason.encode!(agents(context))
        answer = Jason.encode!(context.started)

        for text <- [listing, answer] do
          refute text =~ "token"
          refute text =~ ".sock"
        end

        {:ok, context}
      end
    end
  end
end
