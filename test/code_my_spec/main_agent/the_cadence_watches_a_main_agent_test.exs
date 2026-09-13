defmodule CodeMySpec.MainAgent.TheCadenceWatchesAMainAgentTest do
  @moduledoc """
  Who the cadence is started for, and how a stood-down project gets back.

  Two defects QA found on story 1017, both of which end with a cadence that
  never delivers and looks exactly like a project nobody works on.

  `11aea8f5` — the seed read projects with *continuous* agents. Live, this
  project had twelve agents running, one of them `main`, posting real messages
  minutes apart and fielding real questions, and `continuous = false` on every
  one of them. "Nothing is in a loop" was standing in for "there is nobody to
  look in on".

  `5f9fad45` — `resume/1` had no caller anywhere, so a tap-out stood a project
  down for good. The list lives in application env, so on a dev box that
  restarts hourly this reads as self-healing; on a long-lived node it does not
  heal at all.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.MainAgent.Cadence

  defp agent(scope, attrs) do
    {:ok, agent} =
      AgentsRepository.create_agent(
        scope,
        Enum.into(attrs, %{
          provider: "anthropic",
          engine: :alloy,
          working_copy: "/tmp/cadence-#{System.unique_integer([:positive])}",
          working_copy_id: scope.active_working_copy_id
        })
      )

    agent
  end

  defp seeded?(scope) do
    AgentsRepository.main_agent_project_scopes()
    |> Enum.any?(&(&1.active_project_id == scope.active_project_id))
  end

  describe "what the boot sweep wakes" do
    test "a running main agent, even with nothing in continuous mode" do
      scope = full_scope_fixture()
      _main = agent(scope, %{role: "main", status: :running, continuous: false})

      assert seeded?(scope), """
      The exact live state QA met: a main agent running, nothing looping, and
      nothing scheduled to wake it. Reading the continuous flag answers a
      different question from the one the cadence asks.
      """
    end

    test "one that is still starting, because it is one to watch already" do
      scope = full_scope_fixture()
      _main = agent(scope, %{role: "main", status: :starting, continuous: false})

      assert seeded?(scope)
    end

    test "but not a project whose main agent has stopped" do
      scope = full_scope_fixture()
      _main = agent(scope, %{role: "main", status: :stopped, continuous: true})

      refute seeded?(scope),
             "a stopped main agent is nobody to deliver a digest to, continuous or not"
    end

    test "and not a project with busy agents and no main among them" do
      scope = full_scope_fixture()
      _coding = agent(scope, %{role: "coding", status: :running, continuous: true})

      refute seeded?(scope), """
      A digest goes to the main agent. A project without one has nothing to
      wake, and waking it on a timer buys a model call per tick and no reader.
      """
    end
  end

  describe "standing down" do
    setup do
      scope = full_scope_fixture()
      on_exit(fn -> Cadence.resume(scope) end)
      %{scope: scope}
    end

    test "stops the project being woken, and resuming puts it back", %{scope: scope} do
      assert Cadence.running?(scope)

      :ok = Cadence.stand_down(scope)
      refute Cadence.running?(scope)

      :ok = Cadence.resume(scope)

      assert Cadence.running?(scope), """
      Nothing called resume/1 before this, so a tap-out was permanent: a later
      timer ticked and no-oped every time, because the gate still found the
      project in the stood-down list.
      """
    end

    test "reaches only the project that stood down", %{scope: scope} do
      other = full_scope_fixture()

      :ok = Cadence.stand_down(scope)

      assert Cadence.running?(other),
             "one project's decision to finish stopped another project being looked in on"
    end
  end
end
