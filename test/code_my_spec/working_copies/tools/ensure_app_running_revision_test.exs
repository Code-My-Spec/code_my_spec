defmodule CodeMySpec.WorkingCopies.Tools.EnsureAppRunningRevisionTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.Analysis.HarnessRegistry

  test "a healthy app serving an older revision refuses QA without restarting" do
    response = call_tool(%{commit: "old", serving_commit: "old", head: "new"})

    assert match?({:error, _}, response)
    text = response_text(response)
    assert text =~ "Served revision: old"
    assert text =~ "checkout HEAD: new"
    assert text =~ "Do not test against this app yet"
    assert text =~ "restart_app"
    refute text =~ "http://127.0.0.1:12345"
  end

  test "a reload serving HEAD is accepted even when the launch revision is older" do
    response = call_tool(%{commit: "old", serving_commit: "new", head: "new"})

    assert match?({:ok, _}, response)
    assert response_text(response) =~ "serving new at http://127.0.0.1:12345"
  end

  test "a current launch revision is accepted without a separate reload revision" do
    response = call_tool(%{commit: "new", head: "new"})
    assert match?({:ok, _}, response)
  end

  test "missing revision evidence cannot certify an app for QA" do
    for revisions <- [%{commit: "old"}, %{commit: nil, head: "new"}] do
      response = call_tool(revisions)
      assert match?({:error, _}, response)
      assert response_text(response) =~ "unknown"
    end
  end

  defp call_tool(revisions) do
    scope = full_scope_fixture()
    caller = self()
    info = Map.merge(%{status: "serving", url: "http://127.0.0.1:12345"}, revisions)

    pid =
      spawn_link(fn ->
        :ok =
          HarnessRegistry.register_executor(
            scope.active_working_copy_id,
            "revision-test",
            "/tmp/revision-test"
          )

        send(caller, {:registered, self()})

        receive do
          {:"$gen_call", from, {:ensure_app_running, %{}}} ->
            GenServer.reply(from, {:ok, info})
        end
      end)

    assert_receive {:registered, ^pid}, 2_000
    frame = %Frame{assigns: %{current_scope: scope}}

    response =
      ToolLibrary.run(
        "ensure_app_running",
        %{},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    response
  end

  defp response_text({_status, text}) when is_binary(text), do: text

  defp response_text(response) do
    response |> Response.to_protocol() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")
  end
end
