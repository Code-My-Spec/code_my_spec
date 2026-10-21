defmodule CodeMySpec.Devices.RoutineFireTest do
  @moduledoc """
  Story 1136: firing a cloud box's routine. One attempt, the answer read as
  documented: 200 with a session URL, 429 with `Retry-After` (seconds or an HTTP
  date), anything else refused.
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Devices.Device
  alias CodeMySpec.Devices.RoutineFire

  @box %Device{fire_routine_id: "trig_01A", fire_token: "sk-ant-oat01-x"}

  test "a fire is a bearer POST to the routine's fire path" do
    Req.Test.stub(RoutineFire, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/claude_code/routines/trig_01A/fire"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk-ant-oat01-x"]

      Req.Test.json(conn, %{
        "type" => "routine_fire",
        "claude_code_session_url" => "https://claude.ai/code/session_1"
      })
    end)

    assert {:ok, %{session_url: "https://claude.ai/code/session_1"}} = RoutineFire.fire(@box)
  end

  test "a 429 with Retry-After seconds is rate limited, in seconds" do
    Req.Test.stub(RoutineFire, fn conn ->
      conn |> Plug.Conn.put_resp_header("retry-after", "90") |> Plug.Conn.send_resp(429, "{}")
    end)

    assert {:error, {:rate_limited, 90}} = RoutineFire.fire(@box)
  end

  test "a 429 with an HTTP date counts the seconds until it" do
    later =
      DateTime.utc_now()
      |> DateTime.add(600, :second)
      |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

    Req.Test.stub(RoutineFire, fn conn ->
      conn |> Plug.Conn.put_resp_header("retry-after", later) |> Plug.Conn.send_resp(429, "{}")
    end)

    assert {:error, {:rate_limited, seconds}} = RoutineFire.fire(@box)
    assert seconds in 590..600
  end

  test "a 429 with no Retry-After is rate limited with no time" do
    Req.Test.stub(RoutineFire, &Plug.Conn.send_resp(&1, 429, "{}"))
    assert {:error, {:rate_limited, nil}} = RoutineFire.fire(@box)
  end

  test "any other refusal is a refusal" do
    Req.Test.stub(RoutineFire, &Plug.Conn.send_resp(&1, 401, "{}"))
    assert {:error, {:refused, 401}} = RoutineFire.fire(@box)
  end

  test "a box with no routine or token fires nothing" do
    assert {:error, :no_fire_token} = RoutineFire.fire(%Device{})
  end
end
