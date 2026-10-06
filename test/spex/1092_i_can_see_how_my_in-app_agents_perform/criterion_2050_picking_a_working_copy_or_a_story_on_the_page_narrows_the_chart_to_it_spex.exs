defmodule CodeMySpecSpex.Story1092.Criterion2050Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2050 -- Picking a working copy or a story on the page narrows
  the chart to it.

  This checks the page itself carries controls for both dimensions --
  whether narrowing each actually produces correct totals, without
  leaving the page, is covered by 2052 (working copy) and the story half
  of 2032/2033.
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

  spex "The performance page carries controls to pick a working copy or a story",
       criterion: 2050 do
    scenario "the performance page is opened" do
      given_ "a project with the performance page available", context do
        {:ok, context}
      end

      when_ "I look at the performance page", context do
        {:ok, _index, html} = live(context.conn, index_path(context))
        {:ok, Map.put(context, :html, html)}
      end

      then_ "it carries a control to pick a working copy", context do
        assert context.html =~ "working_copy_id",
               "the page carries no control for picking a working copy"

        {:ok, context}
      end

      then_ "and a control to pick a story", context do
        assert context.html =~ "story_id",
               "the page carries no control for picking a story"

        {:ok, context}
      end
    end
  end
end
