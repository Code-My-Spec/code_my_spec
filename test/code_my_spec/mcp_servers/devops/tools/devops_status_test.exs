defmodule CodeMySpec.McpServers.Devops.Tools.DevopsStatusTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Configurations
  alias CodeMySpec.McpServers.Devops.Tools.DevopsStatus
  alias CodeMySpec.Provisioning.RunLock
  alias CodeMySpec.ProvisioningPlan.Sequence
  alias CodeMySpec.ProvisioningPlan.Step
  alias CodeMySpec.ProvisioningPlan.StepRepository
  alias CodeMySpec.Repo
  alias CodeMySpec.Resources

  import Ecto.Query

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

    # The tool's own docstring tells a caller to "call devops_status to watch
    # it converge" after starting a run, and until now nothing here ever
    # looked at whether one was still going — so a caller mid-run and a
    # caller after a hang read identically (6f982579).
    test "says a run is already in progress instead of just the last checklist", %{
      scope: scope,
      project: project
    } do
      {:ok, _} = Configurations.update(scope, %{devops: :prod})
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

      assert_receive :locked, 1_000

      frame = %Frame{assigns: %{current_scope: scope}}
      assert {:reply, response, ^frame} = DevopsStatus.execute(%{}, frame)

      text = response_text(response)

      assert text =~ "A setup run has been in progress",
             "a run is in flight for this project and nothing said so, which is exactly " <>
               "how a still-running setup and a hung one read the same way"

      send(holder, :release)
    end

    test "says nothing about a run when none is in flight", %{scope: scope} do
      {:ok, _} = Configurations.update(scope, %{devops: :prod})

      frame = %Frame{assigns: %{current_scope: scope}}
      assert {:reply, response, ^frame} = DevopsStatus.execute(%{}, frame)

      refute response_text(response) =~ "in progress"
    end

    # 82f09c49: five checks in 75s all read "0 minutes ago". The age was
    # live; floored to whole minutes it could not move, and the agent took a
    # normal build for a hung run.
    test "a run's age is to the second, and names the step it is on", %{
      scope: scope,
      project: project
    } do
      {:ok, _} = Configurations.update(scope, %{devops: :prod})
      _ = step_row(scope, :server, :running, 0, %{})
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

      assert_receive :locked, 1_000

      text = status_text(scope)
      send(holder, :release)

      assert text =~ ~r/in progress since \d\d:\d\d:\d\dZ \(\d+s ago\)/
      assert text =~ "on #{project.name}/server"
      refute text =~ "minutes ago"
    end
  end

  describe "step states" do
    setup %{scope: scope} do
      {:ok, _} = Configurations.update(scope, %{devops: :prod})
      :ok
    end

    # 82f09c49: an error from an earlier run read as fresh, and an errored
    # step as "not converged yet".
    test "an errored step says errored, how long ago, and why", %{scope: scope, project: project} do
      _ =
        step_row(scope, :server, :errored, 45 * 60, %{
          attempted: "run the server step",
          provider_error: "must be owner of database scratch"
        })

      assert status_text(scope) =~
               "#{project.name}/server: errored 45m ago — must be owner of database scratch"
    end

    test "a done step says done and its age", %{scope: scope, project: project} do
      _ = step_row(scope, :repository, :done, 2 * 3600 + 5 * 60, %{})

      assert status_text(scope) =~ "#{project.name}/repository: done 2h 5m ago"
    end

    test "the first paused step is named as holding the sequence", %{
      scope: scope,
      project: project
    } do
      _ = step_row(scope, :email, :paused, 600, %{paused_instructions: "verify the domain"})
      _ = step_row(scope, :inbound, :paused, 60, %{paused_instructions: "give an address"})

      text = status_text(scope)

      assert text =~
               "#{project.name}/email: paused 10m ago, holding the sequence — verify the domain"

      assert text =~ ~r"/inbound: paused 1m \d+s ago — give an address"
    end

    test "a running row with no run behind it is interrupted, not in progress", %{
      scope: scope,
      project: project
    } do
      _ = step_row(scope, :server, :running, 3 * 3600, %{})

      text = status_text(scope)

      assert text =~ "#{project.name}/server: interrupted"
      refute text =~ "in progress"
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
  describe "step_line/2" do
    @ctx %{now: ~U[2026-09-30 22:30:00Z], run?: false, holder: nil}

    defp errored(detail),
      do: %{
        project_name: "Market My Spec",
        key: "deploy",
        step_state: :errored,
        recorded_at: ~U[2026-09-30 22:29:00Z],
        detail: detail
      }

    test "keeps both ends of a long reason, not just one" do
      detail =
        "the reason starts here" <> String.duplicate("m", 3000) <> "the conclusion ends here"

      line = DevopsStatus.step_line(errored(detail), @ctx)

      assert line =~ "the reason starts here"
      assert line =~ "the conclusion ends here"
      assert String.length(line) < String.length(detail)
    end

    test "a short reason is unaffected" do
      assert DevopsStatus.step_line(errored("no server named x"), @ctx) ==
               "Market My Spec/deploy: errored 1m 0s ago — no server named x"
    end

    # 548b3173: per-environment steps listed twice with nothing to tell them apart.
    test "names the environment of a per-environment step" do
      uat = %{
        project_name: "Metric Flow",
        key: :backups,
        environment: "uat",
        step_state: :not_started
      }

      prod = %{uat | environment: "prod"}

      assert DevopsStatus.step_line(uat, @ctx) == "Metric Flow/uat/backups: not started"
      assert DevopsStatus.step_line(prod, @ctx) == "Metric Flow/prod/backups: not started"
    end
  end

  # A step row whose state was recorded `ago` seconds before now.
  defp step_row(scope, key, state, ago, attrs) do
    row =
      StepRepository.upsert(
        scope,
        key,
        nil,
        Map.merge(attrs, %{state: state, position: Sequence.position(key)})
      )

    at = DateTime.add(DateTime.utc_now(), -ago, :second)

    {1, _} =
      Repo.update_all(where(Step, id: ^row.id),
        set: [updated_at: DateTime.truncate(at, :second), started_at: at]
      )

    row
  end

  defp status_text(scope) do
    frame = %Frame{assigns: %{current_scope: scope}}
    {:reply, response, ^frame} = DevopsStatus.execute(%{}, frame)
    response_text(response)
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
