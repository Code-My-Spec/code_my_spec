defmodule CodeMySpecSpex.Story1134.Criterion2323Spex do
  @moduledoc """
  Story 1134 — A dev box's harness starts with its session.
  Criterion 2323 — A brand-new session starts its harness.

  There is no Claude Code cloud VM to pause in a spec. What Sam is given is the
  setup script the environment runs, which installs the SessionStart hook that
  brings the harness up, so this reads the script the Dev boxes page showed him
  (the same surface story 1133 reads) and drives the server half for real: the
  box signing in again, and the channel join.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.DevBoxHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A new session starts its harness without anyone running it", criterion: 2323 do
    scenario "Sam starts a new session" do
      given_ "Sam starts a new session in his Claude cloud environment", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        add_dev_box(live, "cloud-1", "claude_code_cloud")
        {:ok, Map.put(context, :script, shown_setup_script(live))}
      end

      then_ "the harness starts without anyone running it", context do
        assert context.script =~ ~r/hooks[\s\S]*SessionStart|SessionStart[\s\S]*hook/,
               "no SessionStart hook is registered:\n\n#{context.script}"

        assert context.script =~ ~r/CLAUDE_CODE_REMOTE/,
               "the hook does not recognise a cloud session"

        assert context.script =~ ~r/nohup|setsid/,
               "the hook does not start the harness detached from the session"

        {:ok, context}
      end
    end
  end
end
