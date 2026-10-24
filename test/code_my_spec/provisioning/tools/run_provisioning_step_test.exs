defmodule CodeMySpec.Provisioning.Tools.RunProvisioningStepTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.GitHub
  alias CodeMySpec.Provisioning.RunLock

  setup do
    working_dir = CodeMySpec.TempFile.owned_dir("test")
    File.write!(Path.join(working_dir, "README.md"), "# hi\n")

    scope = full_scope_fixture()
    _ = github_integration_fixture(scope.user)
    scope = put_fixture_execution_context(scope, ExecutionContext.new(:local, working_dir))

    %{scope: scope, project: scope.active_project}
  end

  defp stub_github(fun), do: Req.Test.stub(GitHub, fun)

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  describe "execute/2" do
    # The whole point of this tool: run a step out of the sequence's own
    # order, bypassing the halt-on-first-failure wrapper — verified here
    # against a step (:repository) that behaves identically whether it's
    # reached through the sequence or asked for directly.
    test "runs the named step and reports its real outcome", %{scope: scope} do
      stub_github(fn
        %{method: "GET", request_path: "/user"} = conn ->
          json(conn, 200, %{"login" => "johns10"})

        %{method: "GET"} = conn ->
          json(conn, 404, %{})

        %{method: "POST"} = conn ->
          json(conn, 201, %{
            "name" => "sams-thing",
            "clone_url" =>
              Path.join(System.tmp_dir!(), "nowhere-#{System.unique_integer([:positive])}")
          })
      end)

      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{step: "repository"}

      response =
        ToolLibrary.run(
          "run_provisioning_step",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      # The push itself will fail (the stub hands back a bogus, nonexistent
      # clone_url) — what matters here is that the step actually ran and
      # reported a real, specific outcome rather than the tool refusing.
      text = response_text(response)
      assert text =~ "repository for"
    end

    # `Steps.run(:inbound, ...)` already accepts `opts[:inbound_probe_to]` —
    # this tool never exposed a parameter to supply one. Proven without
    # mocking Resend at all: an address on a *different* domain than the
    # project's own is refused before any provider call, by
    # `probe_address_on_domain/2`'s own check — a deterministic outcome that
    # only fires if the parameter actually reached the step.
    test "threads inbound_probe_to through to the step", %{scope: scope, project: project} do
      {:ok, _project} =
        CodeMySpec.Projects.update_project(scope, project, %{domain: "example.com"})

      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{step: "inbound", inbound_probe_to: "sam@somewhere-else.com"}

      response =
        ToolLibrary.run(
          "run_provisioning_step",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert response_text(response) =~
               "sam@somewhere-else.com is not on example.com, so delivering to it would prove nothing"
    end

    test "refuses an unknown step name rather than guessing one", %{scope: scope} do
      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{step: "not_a_real_step"}

      response =
        ToolLibrary.run(
          "run_provisioning_step",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
      assert response_text(response) =~ "unknown step"
    end

    test "reports a run already in progress instead of racing it", %{
      scope: scope,
      project: project
    } do
      test_pid = self()

      {:ok, holder} =
        Task.start(fn ->
          RunLock.with_lock(project.id, fn ->
            send(test_pid, :locked)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :locked

      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{step: "server"}

      response =
        ToolLibrary.run(
          "run_provisioning_step",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
      assert response_text(response) =~ "already in progress"

      send(holder, :release)
    end
  end

  defp response_text({_status, text}), do: text
end
