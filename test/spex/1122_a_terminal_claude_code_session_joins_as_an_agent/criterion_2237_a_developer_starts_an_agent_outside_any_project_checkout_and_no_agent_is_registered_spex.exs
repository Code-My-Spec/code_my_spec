defmodule CodeMySpecSpex.Story1122.Criterion2237Spex do
  @moduledoc """
  Story 1122 — A terminal Claude Code session joins as an agent.
  Criterion 2237 — A developer starts an agent outside any project checkout and no agent is registered.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers

  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox
  alias Phoenix.ConnTest

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Claude Code started outside any checkout registers no agent", criterion: 2237 do
    scenario "a developer opens Claude Code in a directory no project serves" do
      given_ "a harness serving a checkout of the project, and a directory that is not one",
             context do
        context = HarnessHooks.ensure_live_harness(context)

        {:ok, Map.put(context, :elsewhere, not_a_checkout())}
      end

      when_ "the plugin's SessionStart hook runs there", context do
        conn =
          ConnTest.build_conn()
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> ConnTest.dispatch(
            CmsHarness.Web.Endpoint,
            :post,
            "/api/hooks/session-start",
            Jason.encode!(%{"session_id" => session_id(), "cwd" => context.elsewhere})
          )

        {:ok, Map.put(context, :answer, conn)}
      end

      then_ "the session starts normally and no agent is registered", context do
        body = ConnTest.json_response(context.answer, 200)
        refute Map.has_key?(body, "decision")
        assert agents(context) == []
        {:ok, context}
      end
    end
  end
end
