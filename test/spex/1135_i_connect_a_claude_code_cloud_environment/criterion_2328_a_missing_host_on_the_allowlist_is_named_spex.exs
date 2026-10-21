defmodule CodeMySpecSpex.Story1135.Criterion2328Spex do
  @moduledoc """
  Story 1135 — I connect a Claude Code cloud environment.
  Criterion 2328 — A missing host on the allowlist is named.

  A box whose session never reached CodeMySpec has nothing to report, so DevOps
  says what it can know: it has never connected, and which hosts the environment
  must allow.
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

  spex "A box that never connected says which hosts to check", criterion: 2328 do
    scenario "Sam left CodeMySpec's host off the allowlist" do
      given_ "Sam left CodeMySpec's host off the environment's allowlist", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        add_dev_box(live, "cloud-1", "claude_code_cloud")
        {:ok, Map.put(context, :live, live)}
      end

      when_ "a session starts", context do
        # It never reaches us: nothing signs in.
        {:ok, context}
      end

      then_ "the box never connects", context do
        assert context.live
               |> element(
                 "[data-test='dev-box'][data-box-name='cloud-1'] [data-test='dev-box-status']"
               )
               |> render() =~ "Never connected"

        {:ok, context}
      end

      then_ "DevOps says it has never connected and names the hosts to check", context do
        help =
          context.live
          |> element(
            "[data-test='dev-box'][data-box-name='cloud-1'] [data-test='never-connected-help']"
          )
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.text()

        assert help =~ ~r/allowlist|allowed hosts/i
        assert help =~ URI.parse(CodeMySpecWeb.Endpoint.url()).host
        {:ok, context}
      end
    end
  end
end
