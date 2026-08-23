defmodule CodeMySpecTest.InProcessDeviceClient do
  @moduledoc """
  The harness talking to the server without a socket in between.

  Implements `CmsHarness.Device.Client` by driving `CodeMySpecWeb.Endpoint`
  through `Phoenix.ConnTest` — same process, same database sandbox, the real
  router, the real plug pipeline and the real controller. Nothing about the far
  side is faked; only the transport is removed.

  ## Why this exists rather than a stub

  Two reasons, and the first is not about convenience.

  An unpinned `Req` plus a real credential is a live call. Written without this,
  the boot-announce spec POSTed to `https://dev.codemyspec.com/api/devices` with
  a valid bearer token attached, from a test run. It is pinned in
  `config/test.exs` so that is not something a future spec has to remember.

  And a stub would make the spec a tautology — it would assert that a fake
  returns what the fake was told to return. The point of story 1020's criterion
  2846 is that starting the harness genuinely puts a row on the server, so the
  server has to be the real one.

  Same idea as `CmsHarness.Project.Transport`, which put the channel behind a
  seam so `ChannelClient` stopped being testable only by running drills. This is
  that seam for the one call that cannot use the channel at all — a machine
  announcing itself has no project yet, and `harness_project:<id>` is per
  project.
  """

  @behaviour CmsHarness.Device.Client

  import Phoenix.ConnTest

  @endpoint CodeMySpecWeb.Endpoint

  @impl true
  def announce(device_id, token, attrs) do
    body =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> put_present("device_id", device_id)

    build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post("/api/devices", body)
    |> issued()
  end

  defp issued(%Plug.Conn{status: 200} = conn) do
    case Phoenix.ConnTest.json_response(conn, 200) do
      %{"device_id" => id} = body when is_binary(id) ->
        {:ok, %{device_id: id, working_copies: body["working_copies"] || %{}}}

      other ->
        {:error, {200, other}}
    end
  end

  defp issued(%Plug.Conn{status: status} = conn),
    do: {:error, {status, Phoenix.ConnTest.response(conn, status)}}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
