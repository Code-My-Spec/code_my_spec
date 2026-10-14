defmodule CodeMySpecSpex.Story1047.Criterion2068Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 2068 — An agent whose queue is empty stops without calling
  tap_out, and that is the correct outcome.

  Ending a turn on an empty queue with no `tap_out` call is not an
  infraction: nothing was ever offered to decline or ignore, so there is
  nothing for main to be told about, and the turn ends cleanly.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers, only: [put_to_work: 1, frame: 1]
  import CodeMySpecSpex.OfferHelpers, only: [offers: 3]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "An empty queue is stopped out of, not tapped out of", criterion: 2068 do
    scenario "a coder's turn ends on an empty queue, with no tap_out call, and main hears nothing about it" do
      given_ "a coder with nothing actionable, and a main agent watching the project", context do
        context = ProjectStateFixtures.apply_project_kickoff(context)
        {:reply, response, _} = GetNextRequirement.execute(%{}, frame(context))
        refute response.isError, response_text(response)

        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        assert Fixtures.role_queue_size(context.scope, coder.id) == 0

        {:ok, _} =
          WorkingCopies.designate_main(context.scope, context.scope.active_working_copy_id)

        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        :ok = Fixtures.put_agent_mid_turn(context.scope, main.id)

        context = put_to_work(context)
        :ok = Fixtures.put_agent_mid_turn(context.scope, coder.id)

        {:ok, Map.merge(context, %{coder: coder.id, main_id: main.id})}
      end

      when_ "the coder ends its turn on that empty queue, calling no tap_out", context do
        :ok = Fixtures.end_turn(context.scope, context.coder)
        {:ok, context}
      end

      then_ "nothing was ever offered to decline, and main hears no held-back notice about it",
            context do
        assert offers(context, context.coder, %{kind: "work"}) == []

        refute Enum.any?(
                 offers(context, context.main_id, %{kind: "stalled"}),
                 &(&1.subject == "agent:#{context.coder}")
               )

        {:ok, context}
      end
    end
  end
end
