defmodule CodeMySpecSpex.Story1059.Criterion3320Spex do
  @moduledoc """
  Story 1059 — The main agent looks in on its agents on a cadence.
  Criterion 3320 — A quiet check-in does not become a notification.

  Rule: the person hears from the cadence only when it found something.

  A check-in every twenty minutes is seventy-two a day. If each one reaches the
  person, the cadence is a pager that fires on a timer rather than on an event,
  and the reasonable response is to turn it off — which removes the one
  mechanism that catches a silent agent.

  So the cost of getting this wrong is not annoyance. It is that the feature
  gets disabled, and the failure it existed to catch goes back to being
  invisible.

  ## Quiet means nothing found, not nothing happening

  The scenario has agents working normally and nothing wrong. The main agent is
  still woken and still looks — that is 3317 — and what must not happen is
  anything reaching the person's notifications.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Finding nothing is not news" do
    scenario "every agent is working as expected" do
      given_ "agents working normally and nothing wrong", context do
        reply = join_working_copy(context, "/tmp/spex-3320", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        _main = Fixtures.running_agent(scope, role: "main", working_copy: "/tmp/spex-3320")
        Fixtures.record_machine_tools(scope, ["Read", "Write", "Bash"])

        coding = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3320")

        {_agent, _task} =
          Fixtures.agent_task_fixture(scope, coding, requirement_name: "implementation_file")

        :ok = Fixtures.agent_said(scope, coding, "working on it")

        {:ok, Map.put(context, :scope, scope)}
      end

      when_ "the cadence comes round and finds nothing wrong", context do
        :ok = Fixtures.cadence_tick(context.scope)

        {:ok, context}
      end

      then_ "nothing reaches the person", context do
        {:ok, _live, html} = live(context.conn, "/app/notifications")

        refute html =~ ~r/check-?in/i,
               """
               A check-in that found nothing told the person about it.

               Seventy-two a day, each one saying nothing happened. The
               reasonable response is to turn the cadence off, which removes the
               one mechanism that catches a silent agent — so the cost of this
               is not annoyance, it is the feature being disabled and the
               failure it existed to catch going back to invisible.

               notifications:
               #{html}
               """

        {:ok, context}
      end
    end
  end
end
