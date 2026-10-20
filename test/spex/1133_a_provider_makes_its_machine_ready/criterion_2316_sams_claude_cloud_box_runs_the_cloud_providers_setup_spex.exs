defmodule CodeMySpecSpex.Story1133.Criterion2316Spex do
  @moduledoc """
  Story 1133 — A provider makes its machine ready.
  Criterion 2316 — Sam's Claude cloud box runs the cloud provider's setup.

  The cloud provider has no interactive desktop to click through — its
  machine is readied by the setup script Sam pastes into the environment's
  setup box when he adds the dev box, and that script is what the
  environment runs on the box's first session. There being no live Claude
  Code cloud sandbox to boot in a spec, this drives the real surface Sam
  actually sees — `CodeMySpecWeb.DeviceLive.Index`, the same page story
  1130 drives — and reads the real script text it shows him, the one
  that runs at that moment.
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

  spex "The cloud provider's setup script does what a machine needs", criterion: 2316 do
    scenario "Sam added a Claude Code cloud box" do
      given_ "Sam added a Claude Code cloud box", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        add_dev_box(live, "cloud-1", "claude_code_cloud")
        {:ok, Map.put(context, :live, live)}
      end

      when_ "its first session starts, running the setup script the box was shown", context do
        script =
          context.live
          |> element("[data-test='setup-script']")
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.text()

        {:ok, Map.put(context, :setup_script, script)}
      end

      then_ "Postgres is started", context do
        assert context.setup_script =~ ~r/postgres(?:ql)?\s+start/i,
               "the setup script does not start Postgres:\n\n#{context.setup_script}"

        {:ok, context}
      end

      then_ "pgvector and inotify-tools are installed", context do
        assert context.setup_script =~ ~r/pgvector/i,
               "the setup script does not install pgvector:\n\n#{context.setup_script}"

        assert context.setup_script =~ ~r/inotify-tools/i,
               "the setup script does not install inotify-tools:\n\n#{context.setup_script}"

        {:ok, context}
      end

      then_ "the proxy workarounds are applied", context do
        assert context.setup_script =~ ~r/proxy/i,
               "the setup script applies no proxy workaround:\n\n#{context.setup_script}"

        {:ok, context}
      end
    end
  end
end
