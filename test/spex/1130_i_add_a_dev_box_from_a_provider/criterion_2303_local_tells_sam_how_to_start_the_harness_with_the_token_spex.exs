defmodule CodeMySpecSpex.Story1130.Criterion2303Spex do
  @moduledoc """
  Story 1130 — I add a dev box from a provider.
  Criterion 2303 — Local tells Sam how to start the harness with the token.
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

  spex "A Local box says how to start its harness", criterion: 2303 do
    scenario "Sam has just added a Local box" do
      given_ "Sam has just added a Local box", context do
        {:ok, live, _html} = open_dev_boxes(context.conn)
        add_dev_box(live, "laptop", "local")
        {:ok, Map.merge(context, %{live: live, token: shown_token(live)})}
      end

      then_ "he is shown how to install cms and start the harness with the token", context do
        instructions =
          context.live |> element("[data-test='setup-local']") |> render()

        assert instructions =~ "cms"
        assert instructions =~ context.token
        {:ok, context}
      end
    end
  end
end
