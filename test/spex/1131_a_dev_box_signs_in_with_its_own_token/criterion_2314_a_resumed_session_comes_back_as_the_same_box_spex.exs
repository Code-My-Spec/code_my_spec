defmodule CodeMySpecSpex.Story1131.Criterion2314Spex do
  @moduledoc """
  Story 1131 — A dev box signs in with its own token.
  Criterion 2314 — A resumed session comes back as the same box.
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

  spex "A paused and resumed session is the same box", criterion: 2314 do
    scenario "the harness signs in again with the same token" do
      given_ "'cloud-1' signed in, then its session was paused and resumed", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        box = add_box(live, "cloud-1", "claude_code_cloud")
        first = exchanged(box.token)
        {:ok, Map.merge(context, %{box: box, first: first})}
      end

      when_ "its harness signs in again with the same token", context do
        {:ok, Map.put(context, :again, exchanged(context.box.token))}
      end

      then_ "it is 'cloud-1', not a second box", context do
        assert context.again["device_id"] == context.first["device_id"]
        assert context.again["device_id"] == context.box.id

        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        assert has_element?(live, "[data-test='dev-box'][data-box-name='cloud-1']")

        assert render(live) |> String.split("data-box-name=") |> length() == 2,
               "signing in again made another box"

        {:ok, context}
      end
    end
  end
end
