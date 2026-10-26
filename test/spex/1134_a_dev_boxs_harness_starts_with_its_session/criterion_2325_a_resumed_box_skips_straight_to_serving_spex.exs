defmodule CodeMySpecSpex.Story1134.Criterion2325Spex do
  @moduledoc """
  Story 1134 — A dev box's harness starts with its session.
  Criterion 2325 — A resumed box skips straight to serving.

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

  spex "A resumed box does not set up again", criterion: 2325 do
    scenario "setup finished before the recycle and the files survived" do
      given_ "Sam's box finished setup before it was recycled and its files survived", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        add_dev_box(live, "cloud-1", "claude_code_cloud")
        {:ok, Map.put(context, :script, shown_setup_script(live))}
      end

      then_ "it starts the harness and the app without running setup again", context do
        assert context.script =~ ~r/if \[ ! -f \.cms_harness\.json \]/,
               "the session hook onboards even when the checkout already is:\n\n#{context.script}"

        assert context.script =~ ~r/if \[ ! -x \/opt\/otp\/bin\/erl \]/,
               "the toolchain is installed again on a box that has it"

        assert context.script =~
                 ~s(curl --noproxy "*" --max-time 5 -fs "http://127.0.0.1:$port/health"),
               "the hook starts a second harness when one is already up"

        {:ok, context}
      end
    end
  end
end
