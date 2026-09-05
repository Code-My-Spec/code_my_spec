defmodule CodeMySpec.Agents.PlatformTurnCapTest do
  @moduledoc """
  Story 875. The first conversation runs on our credential, so that a visitor
  who signed up ninety seconds ago is not sent through an OAuth flow to see
  their own project working.

  `Credential`'s own doc gave the reason that arrangement was off by default:
  "Nothing bounds that yet: no turn cap, no token budget, no expiry." This is
  the turn cap. It is what lets the platform credential be switched on at all,
  so the tests that matter are the ones about it actually binding — a cap that
  silently never fires is worse than no cap, because the configuration says the
  spend is bounded.

  The two halves are equally load-bearing: it stops an agent we are paying for,
  and it does not touch one the visitor is paying for.
  """
  # Sync: reads and writes application config other tests must not see change.
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Credential
  alias CodeMySpec.Conversations
  alias CodeMySpec.Users.Scope

  setup do
    prior = Application.get_env(:code_my_spec, Credential)
    on_exit(fn -> restore(prior) end)

    user = user_fixture()
    account = account_fixture(%{name: "Cap #{System.unique_integer([:positive])}"})

    scope = %Scope{
      user: user,
      user_id: user.id,
      active_account: account,
      active_account_id: account.id
    }

    project = project_fixture(scope)

    scope = %Scope{scope | active_project: project, active_project_id: project.id}

    {:ok, scope: scope}
  end

  defp restore(nil), do: Application.delete_env(:code_my_spec, Credential)
  defp restore(config), do: Application.put_env(:code_my_spec, Credential, config)

  defp on_our_credential,
    do: Application.put_env(:code_my_spec, Credential, platform_api_key: "sk-platform")

  defp on_nobodys_credential, do: Application.delete_env(:code_my_spec, Credential)

  # A row, not a running process. The cap is a decision made before anything is
  # dispatched, so it is answerable without a machine on the other end — which
  # is the point: it must refuse before it spends, not after.
  defp agent_row(scope, provider) do
    # A real copy, because an agent's `working_copy_id` is a foreign key -- an
    # invented one is refused before any of this is reached.
    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    {:ok, agent} =
      CodeMySpec.Agents.AgentsRepository.create_agent(scope, %{
        provider: provider,
        engine: :alloy,
        working_copy: "/tmp/cap-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id,
        role: "main"
      })

    agent
  end

  defp visitor_said(scope, agent, n) do
    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    for i <- 1..n do
      {:ok, _} =
        Conversations.add_message(conversation, :operator, "message #{i}", "operator", [])
    end

    :ok
  end

  describe "an agent we are paying for" do
    test "starts with its whole allowance", %{scope: scope} do
      on_our_credential()
      agent = agent_row(scope, "anthropic")

      assert {0, 10} = Agents.turn_allowance(scope, agent),
             "the allowance is not being reported, so the visitor cannot see a " <>
               "limit coming and can only discover it by hitting it."
    end

    test "counts what the visitor said, not what the agent answered", %{scope: scope} do
      on_our_credential()
      agent = agent_row(scope, "anthropic")
      visitor_said(scope, agent, 3)

      assert {3, 10} = Agents.turn_allowance(scope, agent)
    end

    test "stops answering once the allowance is spent", %{scope: scope} do
      on_our_credential()
      agent = agent_row(scope, "anthropic")
      visitor_said(scope, agent, 10)

      assert {:error, {:turn_cap_reached, 10}} =
               Agents.dispatch_message(scope, agent.id, "one more"),
             "the eleventh message went through, so the cap does not bind and the " <>
               "configuration that says this spend is bounded is not true. A cap " <>
               "that never fires is worse than none: it is a claim nobody checks."
    end

    test "one turn short, the refusal is not the cap's", %{scope: scope} do
      on_our_credential()
      agent = agent_row(scope, "anthropic")
      visitor_said(scope, agent, 9)

      # There is no machine on the other end here, so this cannot succeed --
      # and that is exactly why it is worth asserting. Without it, the test
      # above passes whether the cap fires at ten or the dispatch simply always
      # fails, and those are indistinguishable from a green suite.
      assert {:error, reason} = Agents.dispatch_message(scope, agent.id, "still allowed")

      refute match?({:turn_cap_reached, _}, reason),
             "the cap refused a turn inside the allowance, so it is not counting -- " <>
               "it is refusing. Got: #{inspect(reason)}"
    end

    test "the refusal names the limit, so the message can say which one", %{scope: scope} do
      Application.put_env(:code_my_spec, Credential,
        platform_api_key: "sk-platform",
        platform_turn_cap: 2
      )

      agent = agent_row(scope, "anthropic")
      visitor_said(scope, agent, 2)

      assert {:error, {:turn_cap_reached, 2}} = Agents.dispatch_message(scope, agent.id, "hi"),
             "the cap is not configurable, or the refusal does not carry the number " <>
               "it enforced — and a message that has to hardcode the limit goes " <>
               "stale the first time somebody changes it."
    end
  end

  describe "an agent the visitor is paying for" do
    test "is not capped at all", %{scope: scope} do
      on_nobodys_credential()
      agent = agent_row(scope, "anthropic")

      # No platform credential configured and no integration connected, so this
      # agent is on nobody's credential — which is not the same as being on
      # ours, and must not be capped as though it were.
      assert :uncapped = Agents.turn_allowance(scope, agent),
             "an agent that is not spending our money is being counted against our " <>
               "cap. The cap exists because we are paying; applied to anyone else " <>
               "it is a limit with no reason behind it."
    end

    test "a spent conversation is still uncapped once nothing of ours pays for it", %{
      scope: scope
    } do
      on_our_credential()
      agent = agent_row(scope, "anthropic")
      visitor_said(scope, agent, 50)

      assert {50, 10} = Agents.turn_allowance(scope, agent)

      # The visitor connects their own provider — modelled here by ours going
      # away, which is the same question asked of `Credential.source/2`.
      on_nobodys_credential()

      assert :uncapped = Agents.turn_allowance(scope, agent),
             "the cap outlived the reason for it. It is derived rather than stored " <>
               "precisely so that someone who starts paying for themselves stops " <>
               "being limited, without anything having to notice and update a row."
    end
  end
end
