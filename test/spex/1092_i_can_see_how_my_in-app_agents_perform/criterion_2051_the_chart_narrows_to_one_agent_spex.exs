defmodule CodeMySpecSpex.Story1092.Criterion2051Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2051 -- The chart narrows to one agent.

  This checks the page carries a control to pick one agent -- whether
  narrowing to it actually produces that agent's own totals is covered
  by 2053.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.AgentPerformanceHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The performance page carries a control to pick one agent",
       criterion: 2051 do
    scenario "the performance page is opened" do
      given_ "a project with the performance page available", context do
        # given: already true — `setup :setup_active_project` creates it.
        {:ok, context}
      end

      when_ "I look at the performance page", context do
        {:ok, _index, html} = live(context.conn, index_path(context))
        {:ok, Map.put(context, :html, html)}
      end

      then_ "it carries a control to pick one agent", context do
        assert context.html =~ "agent_id",
               "the page carries no control for picking one agent"

        {:ok, context}
      end
    end
  end
end
