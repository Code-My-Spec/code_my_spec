defmodule CodeMySpecSpex.Story1138.Criterion2336Spex do
  @moduledoc """
  Story 1138 — A dev box says whether it is up.
  Criterion 2336 — A connected box is up.

  Rule: a dev box is up exactly when its harness is connected. Per this
  story's own notes, that reuses the connection signal the Dev boxes page
  already reads from `HarnessRegistry` for its existing Present/Last seen
  column (story 1020) rather than a second liveness system -- joining a
  working copy's real channel for this device is what makes
  `HarnessRegistry.executor_holder/1` answer for it, the same way that
  column already works.

  `[data-test='dev-box-up']` is new: up/down is its own claim, distinct
  from `[data-test='dev-box-status']` (whether the box's token has ever
  signed in at all) and from `[data-test='device-presence']` (the
  existing Present/Last seen wording -- this page's own moduledoc warns
  against ever presenting one liveness signal as another, so up/down gets
  its own element rather than overloading either). This spec names the
  selector the implementation is expected to add.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.DevBoxHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    # The channel is another process; an owner-only sandbox connection is
    # invisible to it.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A dev box is up exactly when its harness is connected", criterion: 2336 do
    scenario "A connected box is up" do
      given_ "'cloud-1''s harness is connected", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        add_dev_box(live, "cloud-1", "claude_code_cloud")
        device_id = box_device_id(live, "cloud-1")

        join_working_copy(context, "/srv/cloud-1/app", "cloud-1", device_id: device_id)

        {:ok, Map.put(context, :device_id, device_id)}
      end

      when_ "Sam opens Dev boxes", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        {:ok, Map.put(context, :live, live)}
      end

      then_ "'cloud-1' is up", context do
        selector =
          "[data-test='device'][data-device-id='#{context.device_id}'] [data-test='dev-box-up']"

        assert has_element?(context.live, selector),
               "the Dev boxes page has no up/down indicator for 'cloud-1' at all"

        text =
          context.live
          |> element(selector)
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.text()

        assert text =~ ~r/\bup\b/i,
               "'cloud-1' is connected but the Dev boxes page does not show it as up:\n\n#{text}"

        refute text =~ ~r/\bdown\b/i,
               "'cloud-1' is connected but the Dev boxes page also shows it as down:\n\n#{text}"

        {:ok, context}
      end
    end
  end
end
