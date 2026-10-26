defmodule CodeMySpecSpex.Story1059.Criterion2483Spex do
  @moduledoc """
  Story 1059 — The main agent looks in on its agents on a cadence.
  Criterion 2483 — A team with nothing in hand is named so main can move it;
  busy teams are only counted, with the call that lists them.

  The decision main makes about teams is "who needs work". A team with nothing
  in hand is that insight; busy teams are a number, and their detail is one
  call away. A line per team would grow with the fleet and bury the one name
  that matters.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.CompactCadenceHelpers, as: Compact
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Free teams are named, busy ones counted", criterion: 2483 do
    scenario "one team holds work and another has nothing in hand" do
      given_ "two copies, each with a coder and a QA, one holding a task", context do
        busy = team(context, "/tmp/spex-2483/team-a", "a")
        _free = team(context, "/tmp/spex-2483/team-b", "b")
        {_qa, _task} = Fixtures.agent_task_fixture(busy.scope, busy.qa)
        {:ok, context}
      end

      when_ "main asks for a check-in", context do
        {:ok, Compact.report(context)}
      end

      then_ "the free team is named and the busy one only counted", context do
        [teams] = Regex.run(~r/teams: [^\n]*/, context.report) || [""]

        assert teams =~ ~r/1 busy; free: team-b — run_script: list_agent_work\(\{\}\)/,
               "The free team is the insight; the busy one is a count.\n\n#{context.report}"

        refute teams =~ "team-a",
               "A busy team is only counted; its detail is behind list_agent_work.\n\n#{teams}"

        {:ok, context}
      end
    end
  end

  defp team(context, root, label) do
    reply = join_working_copy(context, root, label)
    scope = %{context.scope | active_working_copy_id: reply.working_copy_id}
    _coder = Fixtures.running_agent(scope, role: "coding", working_copy: root)
    qa = Fixtures.running_agent(scope, role: "qa", working_copy: root)
    %{scope: scope, qa: qa}
  end
end
