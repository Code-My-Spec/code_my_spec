defmodule CodeMySpecSpex.Story1020.Criterion2842Spex do
  @moduledoc """
  Story 1020 — Each device onboards itself and I can see what is running where.
  Criterion 2842 — My laptop and my cloud box are told apart.

  Rule: Every device on the account is listed, and each says whether it is a
  local machine or a cloud one.

  "Is this running on my machine or somewhere I am paying for" is the question
  the list exists to answer, and it is currently unanswerable: the only trace of
  it is a hostname interpolated into a working copy's free-text label by
  `CmsHarness.Config.label/1`, which `CMS_HARNESS_LABEL` overrides and nothing
  parses.

  The machine reports which it is rather than the server inferring it. A laptop
  authenticates with OAuth and a sprite with a deploy key — `socket_credential/0`
  already picks between them on every connect — so the answer exists at connect
  time and was simply being discarded.

  Both halves are asserted: both listed, and each carrying its own kind. A page
  that lists them and calls them the same thing has answered nothing.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.DeviceHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The list says which machines are mine and which are rented" do
    scenario "My laptop and my cloud box are told apart" do
      given_ "a laptop and a provisioned cloud box, both online", context do
        laptop = device_id(context, hostname: "a-laptop", kind: "local")
        sprite = device_id(context, hostname: "a-sprite", kind: "cloud")

        {:ok, context |> Map.put(:laptop, laptop) |> Map.put(:sprite, sprite)}
      end

      when_ "I look at my devices", context do
        {:ok, live, html} = live(context.conn, "/app/devices")

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "both are listed", context do
        assert has_element?(
                 context.live,
                 "[data-test='device'][data-device-id='#{context.laptop}']"
               ),
               "the laptop is missing from the list"

        assert has_element?(
                 context.live,
                 "[data-test='device'][data-device-id='#{context.sprite}']"
               ),
               "the cloud box is missing from the list"

        {:ok, context}
      end

      then_ "and each says which of the two it is", context do
        assert has_element?(
                 context.live,
                 "[data-test='device'][data-device-id='#{context.laptop}'][data-kind='local']"
               ),
               "the laptop does not say it is local"

        assert has_element?(
                 context.live,
                 "[data-test='device'][data-device-id='#{context.sprite}'][data-kind='cloud']"
               ),
               "the cloud box does not say it is a cloud box. Listing both and " <>
                 "calling them the same thing answers nothing — the whole question " <>
                 "is which of my machines I am paying for by the hour."

        {:ok, context}
      end
    end
  end
end
