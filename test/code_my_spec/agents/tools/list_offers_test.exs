defmodule CodeMySpec.Agents.Tools.ListOffersTest do
  @moduledoc "`list_offers`, through `execute/2` and through main's code-mode catalog."
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.{Frame}
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Conversations
  alias CodeMySpec.McpServers.CodeMode, as: Layer

  setup do
    scope = full_scope_fixture()
    coding = agent(scope, "coding")

    {:ok, _} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        coding.id
      )

    %{scope: scope, coding: coding, frame: %Frame{assigns: %{current_scope: scope}}}
  end

  defp agent(scope, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        working_copy: "/tmp/list-offers-#{role}-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id,
        tools: nil
      })

    agent
  end

  defp call(params, frame) do
    response =
      ToolLibrary.run(
        "list_offers",
        params,
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    {match?({:error, _}, response), elem(response, 1)}
  end

  test "lists offers with the count table, messages, and undelivered and unlinked ones", ctx do
    linked =
      ctx.coding
      |> Conversations.record_sent_to_agent(String.duplicate("Eligible work. ", 40))
      |> Offers.record(ctx.coding, :work, {"requirement", "story:1:story_promoted"})

    unlinked = Offers.record(nil, ctx.coding, :problems, {"analysis", "credo"})
    Offers.undelivered(unlinked)

    {error?, text} = call(%{}, ctx.frame)

    refute error?
    assert text =~ "2 offers match; the newest 2 are shown below."
    assert text =~ ~r/kind\s+open\s+undelivered\s+total/
    assert text =~ "offer #{linked.id}"
    assert text =~ "agent: #{ctx.coding.id} (coding)"
    assert text =~ "work on requirement:story:1:story_promoted, attempt 1"
    assert text =~ "template: work/1"
    assert text =~ "status: undelivered — the delivery failed or was held"
    assert text =~ "messages: none linked"
    assert [_, excerpt] = Regex.run(~r/    - [0-9a-f-]+ at \S+: (.*)/, text)
    assert String.length(excerpt) == 301
    assert String.ends_with?(excerpt, "…")
  end

  test "filters by string kind and status", ctx do
    Offers.record(nil, ctx.coding, :work, {"requirement", "a"})
    Offers.record(nil, ctx.coding, :problems, {"analysis", "credo"})

    {false, text} = call(%{"kind" => "work", "status" => "open"}, ctx.frame)
    assert text =~ "1 offers match"
    refute text =~ "analysis:credo"
  end

  test "refuses a kind, status or since it cannot read", ctx do
    assert {true, text} = call(%{kind: "nudge"}, ctx.frame)
    assert text =~ "`kind` \"nudge\" is not one of: work, menu"

    assert {true, text} = call(%{status: "lost"}, ctx.frame)
    assert text =~ "undelivered"

    assert {true, text} = call(%{since: "yesterday"}, ctx.frame)
    assert text =~ "not ISO8601"
  end

  test "refuses another project's agent rather than listing nothing", ctx do
    other = full_scope_fixture()
    theirs = agent(other, "coding")
    Offers.record(nil, theirs, :work, {"requirement", "a"})

    assert {true, text} = call(%{agent_id: theirs.id}, ctx.frame)
    assert text =~ "No agent with that id on this project"
  end

  test "is in main's code-mode catalog and not coding's", ctx do
    main = agent(ctx.scope, "main")

    assert Map.has_key?(Layer.catalog(ctx.scope, Agents.tools_of(ctx.scope, main)), "list_offers")

    refute Map.has_key?(
             Layer.catalog(ctx.scope, Agents.tools_of(ctx.scope, ctx.coding)),
             "list_offers"
           )
  end
end
