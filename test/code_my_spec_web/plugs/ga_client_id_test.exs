defmodule CodeMySpecWeb.Plugs.GaClientIdTest do
  @moduledoc """
  Unit coverage for the GA4 cookie parsing — fed the real cookie shapes gtag.js
  writes, not assumed ones. (A prior session_id bug shipped because a spex seeded
  a made-up GS1 cookie while live gtag emits GS2; this table guards that.)
  """
  use CodeMySpecTest.ConnCase, async: true

  alias CodeMySpec.Analytics.GoogleAnalytics
  alias CodeMySpecWeb.Plugs.GaClientId
  alias Plug.Test

  # The session cookie name is "_ga_<container>" where container = the
  # configured measurement_id minus its "G-" prefix. Derive it the same way
  # the plug does so the test matches whatever the env configures.
  defp session_cookie do
    "G-" <> container = Application.get_env(:code_my_spec, GoogleAnalytics)[:measurement_id]
    "_ga_" <> container
  end

  # Real-world samples:
  @ga "GA1.1.987654321.1700000000"
  @ga_client_id "987654321.1700000000"
  @gs2 "GS2.1.s1779821354$o1$g0$t1779821354$j60$l0$h0"
  @gs2_session_id "1779821354"
  @gs1 "GS1.1.1788888888.3.1.1788888899.0.0.0"
  @gs1_session_id "1788888888"

  defp run(cookies) do
    cookies
    |> Enum.reduce(Test.conn(:get, "/"), fn {name, val}, conn ->
      Test.put_req_cookie(conn, name, val)
    end)
    |> Test.init_test_session(%{})
    |> GaClientId.call(GaClientId.init([]))
  end

  defp stitch(conn), do: {get_session(conn, "ga_client_id"), get_session(conn, "ga_session_id")}

  describe "client_id from the _ga cookie" do
    test "parses the <X>.<Y> tail" do
      assert {@ga_client_id, _} = run([{"_ga", @ga}]) |> stitch()
    end

    test "ignores a malformed _ga value" do
      assert {nil, _} = run([{"_ga", "garbage"}]) |> stitch()
      assert {nil, _} = run([{"_ga", "GA1.1."}]) |> stitch()
    end

    test "absent _ga leaves client_id unset" do
      assert {nil, _} = run([]) |> stitch()
    end
  end

  describe "session_id from the _ga_<container> cookie" do
    test "parses the current GS2 format (s<session_id> after the depth field)" do
      assert {_, @gs2_session_id} = run([{session_cookie(), @gs2}]) |> stitch()
    end

    test "parses the legacy GS1 format (field 3)" do
      assert {_, @gs1_session_id} = run([{session_cookie(), @gs1}]) |> stitch()
    end

    test "ignores malformed / unknown-prefix session cookies" do
      assert {_, nil} = run([{session_cookie(), "GS9.1.whatever"}]) |> stitch()
      assert {_, nil} = run([{session_cookie(), "GS2.1.nodigits$o1"}]) |> stitch()
      assert {_, nil} = run([{session_cookie(), "garbage"}]) |> stitch()
    end

    test "absent session cookie leaves session_id unset" do
      assert {_, nil} = run([{"_ga", @ga}]) |> stitch()
    end
  end

  describe "both together" do
    test "GA1 + GS2 → both stitch ids land in the session" do
      assert {@ga_client_id, @gs2_session_id} =
               run([{"_ga", @ga}, {session_cookie(), @gs2}]) |> stitch()
    end

    test "no GA cookies at all → session untouched" do
      assert {nil, nil} = run([{"some_other", "x"}]) |> stitch()
    end
  end
end
