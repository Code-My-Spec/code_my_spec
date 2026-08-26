defmodule CodeMySpecSpex.Story966.Criterion2953Spex do
  @moduledoc """
  Story 966 — I watch my project and talk to its agent on one screen.
  Criterion 2953 — A blocked agent is visible while Sam is looking at something else.

  This is the rule the whole activity tab depends on. An agent that has stopped
  and is waiting costs real time for every minute nobody notices, and on a phone
  — one open panel — a question inside a closed tab is invisible. So the demand
  for attention has to reach the tab header, not just the panel body.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.MainAgentHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  # The screen rides the main agent's conversation, and there is no main agent
  # without somewhere to run it — `ensure_main_agent/1` refuses with
  # `:not_connected`.
  setup %{scope: scope} do
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  spex "A closed tab shows that something inside it is waiting on Sam" do
    scenario "A blocked agent is visible while Sam is looking at something else" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_966")}
      end

      given_ "the preview open and the activity tab closed", context do
        {:ok, live, _html} = live(context.conn, main_conversation_path(context))
        live |> element(~s([data-test="panel-tab-preview"])) |> render_click()

        {:ok, Map.put(context, :live, live)}
      end

      when_ "an agent in another working copy asks a question and stops", context do
        alias Anubis.Server.Frame
        alias CodeMySpec.McpServers.Tasks.Tools.AskUser

        # Genuinely another copy, not this one wearing a different name. The
        # criterion is about a thread that is *not* the one being read, and
        # asking from `context.scope` would ask from the main checkout — whose
        # questions this conversation already shows inline, and which the
        # activity tab therefore excludes on purpose.
        other =
          join_working_copy(context, "/tmp/spex_966_other_copy", "other copy")

        frame = %Frame{
          assigns: %{
            current_scope: %{
              context.scope
              | active_working_copy_id: other["working_copy_id"]
            }
          }
        }

        {:reply, response, _frame} =
          AskUser.execute(%{message: "Which deploy key should I use?"}, frame)

        # Checked, because the tool answers a bad call with an error *response*
        # rather than a raise. Ignoring it means the question was never asked and
        # the assertions below fail against a screen that is behaving correctly.
        refute response.isError,
               "the agent's question was refused, so nothing was ever waiting: " <>
                 inspect(response)

        {:ok, Map.put(context, :html, render(context.live))}
      end

      then_ "the activity tab says something is waiting", context do
        assert context.html =~ ~s(data-test="panel-attention"),
               "a stopped agent raised nothing on the closed activity tab, so it waits " <>
                 "until somebody happens to open the right panel"

        {:ok, context}
      end

      then_ "and opening it shows the question and which copy asked", context do
        html =
          context.live
          |> element(~s([data-test="panel-tab-activity"]))
          |> render_click()

        assert html =~ "Which deploy key should I use?",
               "the activity tab does not show the question that was asked"

        assert html =~ ~s(data-test="activity-source"),
               "the question does not say which working copy asked it, so answering " <>
                 "it means guessing who it is for"

        {:ok, context}
      end
    end
  end
end
