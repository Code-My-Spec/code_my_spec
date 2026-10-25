defmodule CmsHarness.Web.AnalysisControllerTest do
  use ExUnit.Case, async: false

  alias CmsHarness.Channel
  alias CmsHarness.Web.AnalysisController
  alias CmsHarness.WorkingCopies

  setup do
    :meck.new(WorkingCopies, [:passthrough, :no_link])
    :meck.new(Channel, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload([WorkingCopies, Channel]) end)
    :meck.expect(WorkingCopies, :root, fn "analysis-copy" -> {:ok, "/analysis-copy"} end)
    :ok
  end

  defp request(reply) do
    :meck.expect(Channel, :await_analysis, fn
      "/analysis-copy", "exunit", ["test/example_test.exs"] -> reply
    end)

    AnalysisController.run(Plug.Test.conn(:post, "/"), %{
      "harness_id" => "analysis-copy",
      "source" => "exunit",
      "args" => ["test/example_test.exs"]
    })
  end

  test "an unmatched topic identifies a request rejected before execution" do
    conn = request({:error, %{"reason" => "unmatched topic"}})

    assert conn.status == 502
    assert conn.resp_body =~ "rejected before dispatch"
    assert conn.resp_body =~ "This request did not start the analyzer"
    assert conn.resp_body =~ "reconnecting"
    assert conn.resp_body =~ "not an ExUnit exit status"
    assert Plug.Conn.get_resp_header(conn, "x-exit-status") == []
  end

  test "a lost reply does not claim the tests failed or never ran" do
    conn = request({:error, :no_reply})

    assert conn.status == 502
    assert conn.resp_body =~ "execution state and test outcome are unknown"
    assert conn.resp_body =~ "before retrying"
    refute conn.resp_body =~ "did not start"
    assert Plug.Conn.get_resp_header(conn, "x-exit-status") == []
  end

  test "completed passing and failing suites preserve output and their own exit status" do
    for {exit_status, http_status, output} <- [
          {0, 200, "Running ExUnit with seed: 42\n1 test, 0 failures\n"},
          {2, 422, "Running ExUnit with seed: 42\n1 test, 1 failure\n"}
        ] do
      conn =
        request(
          {:ok, %{"status" => "completed", "output" => output, "exit_status" => exit_status}}
        )

      assert conn.status == http_status
      assert conn.resp_body == output
      assert Plug.Conn.get_resp_header(conn, "x-exit-status") == [to_string(exit_status)]
    end
  end

  test "a no-match failure explains suite selection without rewriting analyzer output" do
    output = ~s(Paths given to "mix test" did not match any directory/file: test/spex/new_story\n)
    conn = request({:ok, %{"status" => "completed", "output" => output, "exit_status" => 1}})

    assert conn.status == 422
    assert conn.resp_body == output
    assert Plug.Conn.get_resp_header(conn, "x-exit-status") == ["1"]
    assert [guidance] = Plug.Conn.get_resp_header(conn, "x-analysis-guidance")
    assert guidance =~ "including untracked files"
    assert guidance =~ "mix spex <path>"
    assert guidance =~ "Committing alone does not change test selection"
  end

  test "an unreadable reply cannot become a passing suite" do
    conn = request({:ok, %{"unexpected" => true}})
    assert conn.status == 502
    assert Plug.Conn.get_resp_header(conn, "x-analysis-guidance") == []
    assert conn.resp_body =~ "unreadable analysis reply"
    assert Plug.Conn.get_resp_header(conn, "x-exit-status") == []
  end
end
