defmodule CmsHarness.AppInstance.Runner.LocalProbeTest do
  @moduledoc """
  2026-09-29, Harness session: a live QA defect on metric_flow — a copy's
  `assets/node_modules` was never installed, so its JS bundle built to
  nothing. `GET /` still answered 200 (nothing about a missing
  `node_modules` fails compile or boot), so the copy read as "serving"
  while every `phx-click` on the page was silently inert. QA found this by
  hand; nothing in the health probe said so.

  `probe/1` now also checks `/assets/js/app.js` — Phoenix 1.8's own
  dev-mode bundle path, unhashed unlike a prod digest — and reports
  `:erroring` rather than `:serving` when it doesn't answer. Toolchain
  agnostic on purpose: this asks whether the URL a real browser would
  request actually answers, not whether esbuild printed an error.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.AppInstance.Runner.Local
  alias Req.Test

  test "both / and the JS bundle answer: serving" do
    Test.stub(Local, &ok_root_and_js/1)

    assert Local.probe(0) == :serving
  end

  test "an older app without /health still serves when / and JS answer" do
    Test.stub(Local, fn
      %{request_path: "/health"} = conn -> Plug.Conn.send_resp(conn, 404, "not found")
      conn -> ok_root_and_js(conn)
    end)

    assert Local.probe(0) == :serving
  end

  test "/ answers but /health reports failure: erroring, not serving" do
    Test.stub(Local, fn
      %{request_path: "/health"} = conn -> Plug.Conn.send_resp(conn, 503, "unhealthy")
      conn -> ok_root_and_js(conn)
    end)

    assert Local.probe(0) == :erroring
  end

  test "/ answers but /health cannot be reached: down, not serving" do
    Test.stub(Local, fn
      %{request_path: "/health"} = conn -> Test.transport_error(conn, :econnrefused)
      conn -> ok_root_and_js(conn)
    end)

    assert Local.probe(0) == :down
  end

  test "/ answers but the JS bundle 404s: erroring, not serving" do
    Test.stub(Local, &ok_root_missing_js/1)

    assert Local.probe(0) == :erroring
  end

  test "/ answers but the JS bundle never responds: erroring, not serving" do
    Test.stub(Local, &ok_root_unreachable_js/1)

    assert Local.probe(0) == :erroring
  end

  test "/ itself answers 5xx: erroring, the JS bundle is never even asked" do
    Test.stub(Local, &erroring_root_flunks_on_js/1)

    assert Local.probe(0) == :erroring
  end

  test "/ is unreachable: down, the JS bundle is never even asked" do
    Test.stub(Local, &unreachable_root_flunks_on_js/1)

    assert Local.probe(0) == :down
  end

  defp ok_root_and_js(%{request_path: "/assets/js/app.js"} = conn), do: Test.text(conn, "// js")
  defp ok_root_and_js(conn), do: Test.text(conn, "ok")

  defp ok_root_missing_js(%{request_path: "/assets/js/app.js"} = conn),
    do: Plug.Conn.send_resp(conn, 404, "not found")

  defp ok_root_missing_js(conn), do: Test.text(conn, "ok")

  defp ok_root_unreachable_js(%{request_path: "/assets/js/app.js"} = conn),
    do: Test.transport_error(conn, :econnrefused)

  defp ok_root_unreachable_js(conn), do: Test.text(conn, "ok")

  defp erroring_root_flunks_on_js(%{request_path: "/assets/js/app.js"}),
    do: flunk("the JS bundle should never be requested when / itself is erroring")

  defp erroring_root_flunks_on_js(conn), do: Plug.Conn.send_resp(conn, 500, "boom")

  defp unreachable_root_flunks_on_js(%{request_path: "/assets/js/app.js"}),
    do: flunk("the JS bundle should never be requested when / itself is down")

  defp unreachable_root_flunks_on_js(conn), do: Test.transport_error(conn, :econnrefused)
end
