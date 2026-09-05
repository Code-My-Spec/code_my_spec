defmodule CodeMySpecSpex.Story966.Criterion2954Spex do
  @moduledoc """
  Story 966 — I watch my project and talk to its agent on one screen.
  Criterion 2954 — Ordinary progress does not ask for attention.

  The inverse of 2953, and the half that keeps it useful. A badge that lights up
  for routine progress is a badge nobody reads, and once it is ignored the
  blocked-agent case it exists for is lost with it.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.MainAgentHelpers

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
    scenario "Ordinary progress does not ask for attention" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_966")}
      end

      given_ "the activity tab closed", context do
        {:ok, live, _html} = live(context.conn, main_conversation_path(context))
        {:ok, Map.put(context, :live, live)}
      end

      when_ "an agent finishes some work and reports progress", context do
        html =
          render_hook(context.live, "agent_progress", %{
            "working_copy" => "spex_966",
            "message" => "finished three criteria"
          })

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the activity tab does not claim anything is waiting on me", context do
        assert context.html =~ ~s(data-test="conversation-panels"),
               "the panels are not on the screen, so this proves nothing about what " <>
                 "they are or are not claiming"

        refute context.html =~ ~s(data-test="panel-attention"),
               "routine progress raised the attention mark. A badge that lights up for " <>
                 "everything is a badge nobody reads, and the blocked agent it exists " <>
                 "for is lost with it."

        {:ok, context}
      end

      # John, on redesigning this panel: it is working copies, their agents,
      # and a question-waiting indicator now — not a feed. Ambient progress
      # like this has nowhere to render inline any more; the badge assertion
      # above is what this criterion still owns.
    end
  end
end
