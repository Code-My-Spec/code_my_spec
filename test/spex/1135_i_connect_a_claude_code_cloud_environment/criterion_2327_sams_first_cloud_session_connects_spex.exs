defmodule CodeMySpecSpex.Story1135.Criterion2327Spex do
  @moduledoc """
  Story 1135 — I connect a Claude Code cloud environment.
  Criterion 2327 — Sam's first cloud session connects.

  The session's harness trades the token the proxy supplies and joins its
  project, naming the preview address its app answers on. The Dev boxes page
  shows the box connected and links that address.
  """
  use CodeMySpecSpex.Case, async: false

  import CodeMySpecSpex.DevBoxHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The first session shows the box connected with its app reachable", criterion: 2327 do
    scenario "Sam starts a session in his configured environment" do
      given_ "Sam set up his Claude environment as DevOps said", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        box = add_box(live, "cloud-1", "claude_code_cloud")
        {:ok, Map.merge(context, %{live: live, box: box})}
      end

      when_ "he starts a session in it", context do
        access = exchanged(context.box.token)["access_token"]

        {:ok, _reply, _socket} =
          join_project_as_box(access, context.project.id, context.box.id, %{
            "app" => %{"status" => "serving", "url" => "http://localhost:4000"}
          })

        {:ok, context}
      end

      then_ "Dev boxes shows the box connected", context do
        eventually(fn ->
          assert context.live
                 |> element(
                   "[data-test='dev-box'][data-box-name='cloud-1'] [data-test='dev-box-status']"
                 )
                 |> render() =~ "Connected"
        end)

        {:ok, context}
      end

      then_ "and its app reachable at its preview address", context do
        eventually(fn ->
          assert has_element?(
                   context.live,
                   "[data-test='dev-box'][data-box-name='cloud-1'] [data-test='dev-box-preview'][href^='http']"
                 )
        end)

        {:ok, context}
      end
    end
  end
end
