defmodule CodeMySpecSpex.DevBoxHelpers do
  @moduledoc """
  The surface story 1130's criteria drive: the Dev boxes page (`/app/devices`,
  `CodeMySpecWeb.DeviceLive.Index`) and a harness signing in with a box's token.

  The page's hooks, which the implementation follows:

    * `[data-test='add-dev-box']` — the Add control (absent for a regular member)
    * `[data-test='add-dev-box-form']` — the form; `dev_box[name]` and a
      `dev_box[provider]` radio per provider (`local`, `claude_code_cloud`)
    * `[data-test='new-dev-box-token']` — the token, in `data-token`, only on the
      page that just added the box
    * `[data-test='dev-box']` — one row per box, with `data-box-name` and
      `data-device-id`, holding `[data-test='dev-box-status']` ("Connected" or
      "Never connected")
    * the provider's instructions: `[data-test='setup-local']`,
      `[data-test='setup-script']`, `[data-test='setup-hosts']`,
      `[data-test='setup-network-secret']`, each with a `[data-test='copy-…']`
      button

  A harness signs in with the token as the bearer credential on the same route
  every machine announces on, `POST /api/devices` (story 1131 owns the exchange
  for a short-lived token; this is the minimal path that ties a connecting
  harness to its box).
  """

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import ExUnit.Assertions

  @endpoint CodeMySpecWeb.Endpoint

  @doc "Open the Dev boxes page as `conn`'s user."
  def open_dev_boxes(conn), do: live(conn, "/app/devices")

  @doc "Choose Add, pick `provider`, name the box and submit; the page after adding."
  def add_dev_box(live, name, provider) do
    live |> element("[data-test='add-dev-box']") |> render_click()

    live
    |> form("[data-test='add-dev-box-form']", dev_box: %{name: name, provider: provider})
    |> render_submit()
  end

  @doc "The token the page is showing for a box just added."
  def shown_token(live) do
    assert has_element?(live, "[data-test='new-dev-box-token']"),
           "the page is not showing a token"

    live
    |> element("[data-test='new-dev-box-token']")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.attribute("data-token")
    |> List.first()
  end

  @doc "The id of the device behind the box named `name`."
  def box_device_id(live, name) do
    live
    |> element("[data-test='dev-box'][data-box-name='#{name}']")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.attribute("data-device-id")
    |> List.first()
  end

  @doc "A harness comes up and signs in with `token`; the decoded announce reply."
  def sign_in_with(token, hostname \\ "a-harness") do
    build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post("/api/devices", %{"hostname" => hostname, "kind" => "cloud"})
    |> json_response(200)
  end
end
