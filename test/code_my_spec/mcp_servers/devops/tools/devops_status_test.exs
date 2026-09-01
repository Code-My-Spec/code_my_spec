defmodule CodeMySpec.McpServers.Devops.Tools.DevopsStatusTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Configurations
  alias CodeMySpec.McpServers.Devops.Tools.DevopsStatus
  alias CodeMySpec.Resources

  setup do
    scope = full_scope_fixture()
    %{scope: scope, project: scope.active_project}
  end

  describe "execute/2" do
    # The whole point: a real incident. A project whose own devops was still
    # :off got back an unrelated project's checklist instead of an answer
    # about itself, because Resources.report/1 is deliberately account-wide
    # (the cross-project dangling checks need to see everything, which is
    # right for a human on /app/resources) and nothing here checked which
    # project was actually asking before handing that back to a harness
    # caller scoped to one project's work.
    test "refuses rather than reporting on a sibling project when this project's devops is off",
         %{scope: scope, project: project} do
      sibling = project_fixture(scope, %{name: "Sibling Project"})
      sibling_scope = Resources.project_scope(scope, sibling)
      {:ok, _} = Configurations.update(sibling_scope, %{devops: :prod})

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = DevopsStatus.execute(%{}, frame)

      assert response.isError == true
      text = response_text(response)
      assert text =~ "devops is off"
      assert text =~ project.name
      refute text =~ "Sibling Project"
    end

    # Found live, the second half of the same incident: the first fix
    # refused cleanly while this project's own devops was off, but once it
    # was turned on the tool still called Resources.report/1 underneath —
    # so a *different* project, independently devops-enabled in the same
    # account, kept appearing in full detail beside the real answer. Both
    # projects devops-on here, on purpose, to prove that specific case.
    test "reports for real once this project's own devops is on, never a sibling's — even when both are on",
         %{scope: scope, project: project} do
      sibling = project_fixture(scope, %{name: "Sibling Project"})
      sibling_scope = Resources.project_scope(scope, sibling)
      {:ok, _} = Configurations.update(sibling_scope, %{devops: :prod})
      {:ok, _} = Configurations.update(scope, %{devops: :prod})

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = DevopsStatus.execute(%{}, frame)

      assert response.isError == false
      text = response_text(response)
      assert text =~ project.name
      refute text =~ "Sibling Project"
    end
  end

  # The bug this guards: a step's own error is trimmed to its most useful
  # tail before it ever reaches here (`Remote.install_kamal/1`,
  # `Steps.with_output/2` — apt/gem/SSHKit chatter buries the real cause
  # first and its own conclusion last), but this line's slice used to keep
  # the *head* of the fully composed "key — reason" string instead, cutting
  # the already-correct tail right back off and losing exactly what the
  # inner fix preserved. Confirmed live: a kamal-install failure's real Ruby
  # backtrace never reached devops_status at all, only the label and exit
  # code in front of it.
  describe "missing_line/1" do
    test "keeps both ends of a long reason, not just one" do
      detail = "the reason starts here" <> String.duplicate("m", 2000) <> "the conclusion ends here"

      line = DevopsStatus.missing_line(%{project_name: "Market My Spec", key: "deploy", detail: detail})

      assert line =~ "the reason starts here"
      assert line =~ "the conclusion ends here"
      assert String.length(line) < String.length(detail)
    end

    test "a short reason is unaffected" do
      line = DevopsStatus.missing_line(%{project_name: "Market My Spec", key: "deploy", detail: "no server named x"})

      assert line == "Market My Spec/deploy — no server named x"
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
