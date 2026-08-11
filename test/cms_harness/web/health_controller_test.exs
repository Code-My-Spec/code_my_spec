defmodule CmsHarness.Web.HealthControllerTest do
  @moduledoc """
  "Which code is answering" has to be one request, not a diagnosis.

  Finding out which checkout served `localhost:4004` took `lsof` for the pid and
  then `git merge-base` to place it — every time, and answered wrong more than
  once, because a harness that has reconnected looks exactly like one running
  the code you just pushed. `f32c4a4a` asked for this outright.

  `build_drift` is the half that catches skew. A harness keeps running while its
  checkout moves under it, and a server and harness on different commits speak
  different channel contracts: `{:error, %{"reason" => "unmatched topic"}}` on
  every stop, which reads as a connection problem and is not one. That cost two
  agents an afternoon before `BootVersion.drift/0` put it in the stop message;
  this puts the same fact somewhere you can ask for it before stopping.
  """

  use CmsHarnessTest.ConnCase, async: false

  test "it names the commit the harness booted from", %{conn: conn} do
    body = conn |> get("/health") |> json_response(200)

    assert is_binary(body["build"])
    assert body["build"] != ""
  end

  # Present whether or not it has drifted, because a caller checking for skew
  # should not have to tell "no drift" from "this field does not exist".
  test "it always carries the drift key", %{conn: conn} do
    body = conn |> get("/health") |> json_response(200)

    assert Map.has_key?(body, "build_drift")
  end

  # The existing promise, kept: up and reaching nothing are different answers,
  # and neither is readable off a 200 alone.
  test "it still separates being up from being able to reach anything", %{conn: conn} do
    body = conn |> get("/health") |> json_response(200)

    assert body["status"] == "up"
    assert Map.has_key?(body, "serving")
    assert Map.has_key?(body, "degraded")
  end
end
