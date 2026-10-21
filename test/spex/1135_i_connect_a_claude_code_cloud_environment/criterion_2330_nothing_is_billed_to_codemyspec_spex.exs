defmodule CodeMySpecSpex.Story1135.Criterion2330Spex do
  @moduledoc """
  Story 1135 — I connect a Claude Code cloud environment.
  Criterion 2330 — Nothing is billed to CodeMySpec.

  A cloud box runs on Anthropic's machine and Sam's plan. CodeMySpec's side of it
  is a device record and a token: adding the box and its connecting start no
  container, server or workspace of ours.
  """
  use CodeMySpecSpex.Case, async: false

  import CodeMySpecSpex.DevBoxHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "CodeMySpec provisions nothing for a cloud box", criterion: 2330 do
    scenario "the box ran all day" do
      given_ "Sam's cloud box ran agents all day", context do
        Fixtures.install_workspace_runner(healthy?: true, serving: :serving)
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        box = add_box(live, "cloud-1", "claude_code_cloud")
        access = exchanged(box.token)["access_token"]
        {:ok, _reply, _socket} = join_project_as_box(access, context.project.id, box.id)
        {:ok, Map.put(context, :box, box)}
      end

      then_ "CodeMySpec provisions nothing for it", context do
        assert Fixtures.workspace_start_calls() == [],
               "adding or connecting a cloud box started something of ours"

        assert Fixtures.workspace_mounted_files() == %{}
        {:ok, context}
      end
    end
  end
end
