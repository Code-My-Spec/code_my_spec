defmodule CodeMySpecSpex.Story1019.Criterion2837Spex do
  @moduledoc """
  Story 1019 — I can see my working copies and what is running on each.
  Criterion 2837 — Nothing here ends an agent or a harness.

  Rule: This page watches and talks; it does not start or kill anything.

  A deliberate absence, which is the kind of thing that gets added back by
  someone who reads the page and thinks a stop button is obviously missing. It
  is not missing.

  A harness is installed and run on its machine. It starts Pi agents, or someone
  starts a Claude Code agent and connects it through the plugin. Lifecycle
  belongs where the process is; a page reaching across to end it is a different
  kind of thing from a page showing what is happening.

  The tools exist and are deliberately not wired here — `stop_agent` works, and
  story 1018's QA drove it end to end. So this asserts a decision rather than a
  limitation, which is why it is written down: without it, the next person to
  touch this page has every reason to add the button.

  There is also a safety argument that will expire. Rule 4's names do not exist
  yet, and while two rows are mutually indistinguishable a stop control is a way
  to kill the wrong agent — which is exactly what nearly happened during 1018's
  QA with three identical rows on screen.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Watching is not managing" do
    scenario "Nothing here ends an agent or a harness" do
      given_ "working copies with agents running on them", context do
        join_working_copy(context, "/tmp/spex-1019-a", "checkout a")
        join_working_copy(context, "/tmp/spex-1019-b", "checkout b")

        report_agents(context, [
          pi_agent("/tmp/spex-1019-a"),
          claude_agent("/tmp/spex-1019-b")
        ])

        {:ok, context}
      end

      when_ "an engineer looks at them", context do
        {:ok, live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "there is nothing that stops an agent", context do
        refute has_element?(context.live, "[data-test='stop-agent']"),
               "a stop control appeared. `stop_agent` exists and is deliberately " <>
                 "not wired here: lifecycle belongs to the machine the harness " <>
                 "runs on. It is also unsafe while rule 4's names do not exist — " <>
                 "three indistinguishable rows is how the wrong agent gets killed."

        {:ok, context}
      end

      then_ "and nothing that stops a harness", context do
        refute has_element?(context.live, "[data-test='stop-harness']"),
               "a harness is installed and run on its own machine. A page that " <>
                 "reaches across to end it is a different kind of thing from a page " <>
                 "that shows what is happening."

        {:ok, context}
      end

      then_ "but the agents are still readable", context do
        assert has_element?(
                 context.live,
                 "[data-test='working-copy'][data-root='/tmp/spex-1019-a']"
               ),
               "an anchor, so the refutes above cannot pass on an empty page — " <>
                 "a page rendering nothing has no stop buttons either"

        {:ok, context}
      end
    end
  end
end
