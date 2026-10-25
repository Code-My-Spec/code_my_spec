defmodule CodeMySpecSpex.DevBoxHelpers do
  @moduledoc """
  The surface story 1130's criteria drive: the Dev boxes page (`/app/projects/:id/console/devices`,
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
  require Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  @doc "Open the Dev boxes page as `conn`'s user."
  def open_dev_boxes(conn, project),
    do: live(conn, "/app/projects/#{project.id}/console/devices")

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

  @doc """
  Add a box through the page and return what Sam is shown for it: `%{id:, token:}`.
  """
  def add_box(live, name, provider) do
    add_dev_box(live, name, provider)
    %{id: box_device_id(live, name), token: shown_token(live)}
  end

  @doc """
  A harness trades its box token for an access token: `POST /api/devices/token`
  with the box token as the bearer credential (story 1131). The conn, undecoded,
  so a refusal can be read as well as a success. A nil token sends no credential.
  """
  def exchange(token), do: exchange(token, %{})

  def exchange(token, params) do
    build_conn()
    |> bearer(token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post("/api/devices/token", params)
  end

  @doc "The same trade, expected to succeed: the decoded reply."
  def exchanged(token), do: token |> exchange() |> json_response(200)

  @doc """
  A request as Claude Code cloud sends it: the harness holds no token and sends
  none; the environment's proxy puts the box's token on the request as a bearer
  header, outside the box.
  """
  def through_cloud_proxy(harness_conn, token), do: bearer(harness_conn, token)

  @doc "Open the harness's channel socket with `access_token`: `{:ok, socket}` or an error."
  def connect_socket(access_token),
    do: Phoenix.ChannelTest.connect(CodeMySpecWeb.UserSocket, %{"token" => access_token})

  @doc "Access tokens lasting `seconds`, for the rest of this spex."
  def short_lived_access_tokens(seconds) do
    key = CodeMySpec.Devices
    previous = Application.get_env(:code_my_spec, key, [])
    Application.put_env(:code_my_spec, key, Keyword.put(previous, :access_token_ttl, seconds))
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:code_my_spec, key, previous) end)
  end

  @doc "Sam revokes the box's token from its row on the Dev boxes page."
  def revoke_dev_box(live, device_id) do
    live
    |> element("[data-test='revoke-dev-box'][data-device-id='#{device_id}']")
    |> render_click()
  end

  defp bearer(conn, nil), do: conn

  defp bearer(conn, token),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)

  @doc "The setup script the page showed for the box just added, as text."
  def shown_setup_script(live) do
    live
    |> element("[data-test='setup-script']")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.text()
  end

  @doc """
  The box's harness joins its project's channel on the socket its access token
  opened: `{:ok, reply, socket}` or the refusal.
  """
  def join_project_as_box(access_token, project_id, device_id, extra \\ %{}) do
    {:ok, socket} = connect_socket(access_token)

    Phoenix.ChannelTest.subscribe_and_join(
      socket,
      CodeMySpecWeb.HarnessProjectChannel,
      "harness_project:#{project_id}",
      Map.merge(
        %{"root" => "/workspace/app", "label" => "cloud box", "device" => %{"id" => device_id}},
        extra
      )
    )
  end

  @doc """
  Give a cloud box its Claude Code routine: the form on its row takes the routine
  id (`trig_…`) and the per-routine fire token (story 1136).
  """
  def add_fire_token(live, device_id, routine_id, token) do
    live
    |> element("[data-test='add-fire-token'][data-device-id='#{device_id}']")
    |> render_click()

    live
    |> form("[data-test='fire-token-form'][data-device-id='#{device_id}']",
      fire_token: %{routine_id: routine_id, token: token}
    )
    |> render_submit()
  end

  @doc "Sam presses Start on the box's row; the page once the start has been answered."
  def press_start(live, device_id) do
    live
    |> element("[data-test='start-box'][data-device-id='#{device_id}']")
    |> render_click()

    render_async(live)
  end

  @doc """
  Answer the Claude Code routine fire as Claude does (story 1136): `:ok` is the
  200 with a session, `{:rate_limited, retry_after}` the 429. Every request is
  reported back to this test (`assert_fired/0`, `refute_fired_again/0`).
  """
  def stub_routine_fire(:ok), do: stub_routine_fire(&fired_ok/1)

  def stub_routine_fire({:rate_limited, retry_after}),
    do: stub_routine_fire(&rate_limited(&1, retry_after))

  def stub_routine_fire(answer) when is_function(answer, 1) do
    test_pid = self()

    Req.Test.stub(CodeMySpec.Devices.RoutineFire, fn conn ->
      send(
        test_pid,
        {:routine_fired, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")}
      )

      answer.(conn)
    end)
  end

  defp fired_ok(conn) do
    Req.Test.json(conn, %{
      "type" => "routine_fire",
      "claude_code_session_id" => "session_01XYZ",
      "claude_code_session_url" => "https://claude.ai/code/session_01XYZ"
    })
  end

  defp rate_limited(conn, retry_after) do
    conn
    |> Plug.Conn.put_resp_header("retry-after", retry_after)
    |> Plug.Conn.put_status(429)
    |> Req.Test.json(%{
      "type" => "error",
      "error" => %{"type" => "rate_limit_error", "message" => "Rate limit exceeded"}
    })
  end

  @doc "The routine was fired: `{path, authorization header}`."
  def assert_fired do
    assert_receive {:routine_fired, path, authorization}
    {path, authorization}
  end

  @doc "Nothing fires the routine again."
  def refute_fired_again, do: refute_receive({:routine_fired, _path, _authorization}, 300)
end
