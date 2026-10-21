defmodule CodeMySpecSpex.Story1135.Criterion2329Spex do
  @moduledoc """
  Story 1135 — I connect a Claude Code cloud environment.
  Criterion 2329 — An agent works a story in the cloud box.

  Only the part of this that happens on the server can be driven in a spec: the
  box's harness joins its project on its token, is issued a working copy on the
  box's own device, and reports the browser its QA will drive. Running the tests
  and driving the app are what a real cloud session does, and are QA's to
  confirm live (this is flagged, not faked).
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

  spex "A connected cloud box is a working copy that can take work", criterion: 2329 do
    scenario "the box is connected and a story is assigned to it" do
      given_ "Sam's cloud box is connected", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        box = add_box(live, "cloud-1", "claude_code_cloud")
        access = exchanged(box.token)["access_token"]

        {:ok, reply, _socket} =
          join_project_as_box(access, context.project.id, box.id, %{
            "machine_tools" => ["browser_navigate", "browser_click"],
            "browser_status" => "ready"
          })

        {:ok, Map.merge(context, %{box: box, reply: reply})}
      end

      then_ "it is a working copy on the box, ready to be given work", context do
        assert is_binary(context.reply.working_copy_id)
        assert context.reply.device_id == context.box.id
        {:ok, context}
      end
    end
  end
end
