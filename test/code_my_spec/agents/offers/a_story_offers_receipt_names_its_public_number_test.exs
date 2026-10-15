defmodule CodeMySpec.Agents.Offers.AStoryOffersReceiptNamesItsPublicNumberTest do
  @moduledoc """
  Issue 56a2d806: `get_next_requirement` named a story by its public number
  (1026), but the `reject_offer` receipt for the same offer named a different
  number (964) -- the story's own database id, which `graph_subject/2` was
  interpolating directly instead of resolving to `number` the way `subject/2`
  already does for a resumed task.

  Forces a genuine divergence between a story's `id` and its `number` (not
  guaranteed to differ by accident, since a fresh test project's first story
  often gets both as 1) so the regression is pinned on the right field
  rather than passing by coincidence.
  """
  use CodeMySpecSpex.Case, async: false

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.McpServers.Tasks.Tools.RejectOffer
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.Stories.Story
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen(ctx.scope)
    :ok
  end

  test "a declined story offer names the story's public number, not its database id", ctx do
    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    # Force the divergence this regression is actually about: without this,
    # a fresh test project's lone story could have id == number by
    # coincidence, and the assertion below would pass for the wrong reason.
    renumbered = ctx.story.number + 500

    story =
      Story
      |> Repo.get!(ctx.story.id)
      |> Ecto.Changeset.change(number: renumbered)
      |> Repo.update!()

    refute story.id == story.number,
           "premise: id and number must differ for this regression to mean anything"

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/offers-number-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    assert {:ok, _ref} = Work.request_turn_if_runnable(ctx.scope, agent, :test)

    frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: agent.id}}
    {:reply, reply, _frame} = RejectOffer.execute(%{reason: "already handled elsewhere"}, frame)

    refute reply.isError, inspect(reply)
    text = reply.content |> List.first() |> Map.get("text", "")

    assert text =~ "story:#{story.number}:",
           """
           The reject_offer receipt did not name the story's public number.

           receipt: #{text}
           """

    refute text =~ "story:#{story.id}:",
           """
           The reject_offer receipt named the story's internal database id
           instead of its public number.

           receipt: #{text}
           """
  end
end
