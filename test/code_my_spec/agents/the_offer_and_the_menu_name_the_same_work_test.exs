defmodule CodeMySpec.Agents.TheOfferAndTheMenuNameTheSameWorkTest do
  @moduledoc """
  The turn offer, the stop menu and `get_next_requirement` are one answer.

  Issue a31f1cd6. "Is there work for this role" was computed three ways: `Work`
  dropped nodes any task at the copy held, the menu dropped none, and
  `get_next_requirement` dropped what `start_task` refuses but kept the agent's
  own active task. So an agent holding a blocked task was told by the menu to
  call `get_next_requirement` for work `Work` would never offer it.

  Walked over each role, in a world where that role has work, through the
  states an agent is actually in: nothing held, an offer declined, its own task
  active, its own task blocked and then unblocked, and a teammate holding the
  head.
  """
  use CodeMySpecSpex.Case, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.Agents.Menu
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecTest.RecordingAgentTransport

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()
    :ok
  end

  test "a project just set up: product", ctx do
    ctx = ProjectStateFixtures.apply_project_setup_steps(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    walk(ctx.scope, :product)
  end

  test "kicked off with no story yet: main", ctx do
    ctx = ProjectStateFixtures.apply_project_kickoff(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    walk(ctx.scope, :main)
  end

  test "built up to analysis: coding", ctx do
    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    walk(ctx.scope, :coding)
  end

  test "ready for QA: qa", ctx do
    ctx = FullSatisfactionFixtures.apply_without_qa_story(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    walk(ctx.scope, :qa)
  end

  defp walk(scope, role) do
    agent = agent(scope, role)
    agree!(scope, agent, "#{role}, nothing held")

    claimable = Work.claimable_work(scope, agent)
    assert [head | _] = claimable, "premise: #{role} has work in this world"

    decline(scope, agent, claimable)
    agree!(scope, agent, "#{role}, offer declined")
    assert %{requirement: name} = Work.damped(scope, reload(agent), claimable)
    assert name == head.name, "the damper names a different head than the offer"
    clear(agent)

    hold(agent, head, %{status: :active})
    agree!(scope, agent, "#{role}, its own task active on the head")
    clear(agent)

    hold(agent, head, %{status: :blocked, blocker_type: :manual, blocker_id: "x"})
    agree!(scope, agent, "#{role}, its own task blocked on the head")
    clear(agent)

    hold(agent, head, %{
      status: :blocked,
      blocker_type: :manual,
      blocker_id: "x",
      blocker_resolved_at: DateTime.utc_now()
    })

    agree!(scope, agent, "#{role}, its own task blocked and the blocker resolved")
    clear(agent)

    teammate = agent(scope, teammate_role(role))
    hold(teammate, head, %{status: :active})
    agree!(scope, agent, "#{role}, a teammate holds the head")
    clear(teammate)
  end

  defp teammate_role(:main), do: :product
  defp teammate_role(_role), do: :main

  # The menu's requirements count, `Work`'s list and `get_next_requirement`'s
  # head, for one agent in one state.
  defp agree!(scope, agent, state) do
    agent = reload(agent)
    claimable = Work.claimable_work(scope, agent)
    menu = scope |> Menu.live(agent.role, agent) |> Keyword.get(:requirements, 0)

    assert menu == length(claimable), """
    #{state}: the stop menu counts #{menu} requirement(s), and Work offers #{length(claimable)}:
    #{inspect(Enum.map(claimable, & &1.name))}
    """

    assert next_head(scope, agent) == (List.first(claimable) && List.first(claimable).name), """
    #{state}: get_next_requirement leads with something other than the head of Work's list.
    """
  end

  defp next_head(scope, agent) do
    frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}
    {:reply, response, _} = GetNextRequirement.execute(%{}, frame)
    text = hd(Response.to_protocol(response)["content"])["text"]

    ~r/Execution metadata:\n- (\S+) \(/ |> Regex.run(text) |> head_name()
  end

  defp head_name([_, name]), do: name
  defp head_name(nil), do: nil

  defp agent(scope, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: to_string(role),
        continuous: true,
        status: :running,
        working_copy: "/tmp/agree-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    agent
  end

  defp hold(agent, node, attrs) do
    ref = %{"story" => :story_id, "component" => :component_id, "project" => :project_id}

    task =
      Map.merge(
        %{
          :requirement_name => node.name,
          :started_at => DateTime.utc_now(),
          Map.fetch!(ref, node.entity_type) => node.entity_id
        },
        attrs
      )

    agent |> reload() |> Agent.add_task(task) |> Repo.update!()
  end

  defp clear(agent),
    do:
      agent
      |> reload()
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_embed(:tasks, [])
      |> Repo.update!()

  # Five declines of the same offer, just now: `Work`'s damper is holding it.
  defp decline(scope, agent, claimable) do
    agent
    |> reload()
    |> Ecto.Changeset.change(%{
      declined_offer: Work.offer_fingerprint(scope, agent, claimable),
      declined_offer_at: DateTime.utc_now(),
      declined_offer_count: 5
    })
    |> Repo.update!()
  end

  defp reload(agent), do: Repo.get!(Agent, agent.id)
end
