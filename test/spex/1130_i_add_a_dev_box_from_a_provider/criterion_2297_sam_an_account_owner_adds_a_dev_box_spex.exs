defmodule CodeMySpecSpex.Story1130.Criterion2297Spex do
  @moduledoc """
  Story 1130 — I add a dev box from a provider.
  Criterion 2297 — Sam, an account owner, adds a dev box.
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

  spex "An account owner adds a dev box", criterion: 2297 do
    scenario "Sam opens Dev boxes and chooses Add" do
      given_ "Sam owns his account", context do
        # given: already true — `setup :register_log_in_setup_account` makes Sam the owner.
        {:ok, context}
      end

      when_ "he opens DevOps > Dev boxes and chooses Add", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        live |> element("[data-test='add-dev-box']") |> render_click()
        {:ok, Map.put(context, :live, live)}
      end

      then_ "he can pick a provider and add a box", context do
        assert has_element?(context.live, "[data-test='add-dev-box-form']")
        assert has_element?(context.live, "input[name='dev_box[provider]']")

        context.live
        |> form("[data-test='add-dev-box-form']", dev_box: %{name: "cloud-1", provider: "local"})
        |> render_submit()

        assert has_element?(context.live, "[data-test='dev-box'][data-box-name='cloud-1']")
        {:ok, context}
      end
    end
  end
end
