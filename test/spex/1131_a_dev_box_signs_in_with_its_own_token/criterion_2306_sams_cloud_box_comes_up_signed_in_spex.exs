defmodule CodeMySpecSpex.Story1131.Criterion2306Spex do
  @moduledoc """
  Story 1131 — A dev box signs in with its own token.
  Criterion 2306 — Sam's cloud box comes up signed in.
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

  spex "A cloud box signs in with nobody at the machine", criterion: 2306 do
    scenario "a harness starts with the box's token" do
      given_ "Sam added a dev box and has its token", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        {:ok, Map.put(context, :box, add_box(live, "cloud-1", "claude_code_cloud"))}
      end

      when_ "a harness starts with that token and nobody at the machine", context do
        {:ok, Map.put(context, :reply, exchanged(context.box.token))}
      end

      then_ "it is signed in as that box", context do
        assert context.reply["device_id"] == context.box.id,
               "the harness was not signed in as cloud-1: #{inspect(context.reply)}"

        {:ok, context}
      end

      then_ "and it joins its project's channel with that sign-in, no deploy key", context do
        assert {:ok, %{working_copy_id: id, device_id: device_id}, _socket} =
                 join_project_as_box(
                   context.reply["access_token"],
                   context.project.id,
                   context.box.id
                 )

        assert is_binary(id)
        assert device_id == context.box.id
        {:ok, context}
      end
    end
  end
end
