defmodule CodeMySpecSpex.Story1047.Criterion2067Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 2067 — An agent with nothing actionable for its role is not
  offered work or woken for it.

  Two separate claims, both checked: no turn request reaches it (the wake
  half, already covered elsewhere in this story for a generic message), and
  no `work` offer is ever recorded against it (the offer half, which nothing
  else in this story's existing specs asserts directly).
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.IdleAgentHelpers, only: [put_to_work: 1, frame: 1]
  import CodeMySpecSpex.OfferHelpers, only: [offers: 3]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
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

  spex "Nothing actionable for a role means no wake and no offer", criterion: 2067 do
    scenario "a continuous coder's role has no eligible work anywhere on the project" do
      given_ "a continuous coding agent on a project with no eligible work for its role",
             context do
        context = ProjectStateFixtures.apply_project_kickoff(context)

        response =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, response), response_text(response)

        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        assert Fixtures.role_queue_size(context.scope, coder.id) == 0
        {:ok, Map.put(context, :coder, coder.id)}
      end

      when_ "the project's working copies are switched on", context do
        {:ok, put_to_work(context)}
      end

      then_ "it receives no turn, and no work offer is ever recorded for it", context do
        id = context.coder
        refute_receive {:work_turn_requested, ^id, _ref, _prompt}, 1_000
        assert offers(context, id, %{kind: "work"}) == []
        {:ok, context}
      end
    end
  end
end
