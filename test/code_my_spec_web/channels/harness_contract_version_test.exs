defmodule CodeMySpecWeb.HarnessContractVersionTest do
  @moduledoc """
  A harness and a server that disagree about the contract say so.

  Skew used to surface as `{:error, %{"reason" => "unmatched topic"}}` on every
  stop — a message about topics, for a problem about versions. It was
  diagnosable only because the refusal wrapper appends the harness's boot commit
  and its checkout's current one, leaving the reader to run

      git diff --stat <range> -- lib/cms_harness lib/code_my_spec_web/channels

  and notice the contract had moved. That worked, and it is far too much to ask
  of a message that fires on every stop (c8a7f11d).

  The two version numbers are the contract, so the invariant worth pinning is
  not any particular value — it is that the two ends agree, and that a
  disagreement is *named* rather than inferred.
  """

  # Not async, and not for the usual reason: joining runs the channel's real
  # `join/3`, which registers an analysis executor keyed on the harness. Two of
  # those at once are the collision the registry exists to refuse.
  use CodeMySpecTest.DataCase, async: false

  import Phoenix.ChannelTest
  import CodeMySpec.UsersFixtures

  @endpoint CodeMySpecWeb.Endpoint

  alias CmsHarness.Project.ChannelClient
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  # Read off the two modules rather than hardcoded: a test asserting `1 == 1`
  # would keep passing after somebody bumped one side and forgot the other,
  # which is the entire failure this exists to prevent.
  defp server_contract, do: HarnessProjectChannel.contract_version()
  defp harness_contract, do: ChannelClient.contract_version()

  describe "the two ends of the contract" do
    test "agree on the version they speak" do
      assert harness_contract() == server_contract(),
             "the harness and the server are the two halves of one contract. If you " <>
               "bumped one, bump the other — a mismatch here is the skew this is for."
    end
  end

  describe "a join that names a contract" do
    setup do
      Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
      scope = full_scope_fixture()
      %{scope: scope, project_id: scope.active_project_id}
    end

    test "matching the server's is not refused for the contract", ctx do
      # Not asserting the join *succeeds* — it needs authorization and a harness
      # id, which is a different subject. Only that it is not turned away for
      # the contract.
      result = join_with(ctx.scope, ctx.project_id, %{"contract_version" => server_contract()})

      refute match?({:error, %{reason: "contract_version_mismatch"}}, result)
    end

    test "differing from it is refused, with both numbers named", ctx do
      assert {:error, refusal} =
               join_with(ctx.scope, ctx.project_id, %{"contract_version" => server_contract() + 1})

      assert refusal.reason == "contract_version_mismatch"
      assert refusal.harness_contract == server_contract() + 1
      assert refusal.server_contract == server_contract()

      assert refusal.detail =~ "restart the harness" or refusal.detail =~ "Restart the harness",
             "the refusal has to say what to do — the old one sent people to the network"
    end

    test "the refusal does not send the reader to the network", ctx do
      assert {:error, refusal} =
               join_with(ctx.scope, ctx.project_id, %{"contract_version" => server_contract() + 1})

      refute refusal.detail =~ "unmatched topic",
             "that is the message this replaces, and it is about topics rather than versions"

      refute refusal.reason == "invalid topic"
    end
  end

  describe "a join that names no contract" do
    # A harness that predates the field. Allowed on purpose: refusing it would
    # make this change need a coordinated rollout, and the same reasoning
    # already governs `active_runs` and `working_copy_id` in the same payload.
    test "is not refused for the contract" do
      Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
      scope = full_scope_fixture()
      result = join_with(scope, scope.active_project_id, %{})

      refute match?({:error, %{reason: "contract_version_mismatch"}}, result)
    end
  end

  defp join_with(scope, project_id, payload) do
    UserSocket
    |> socket("harness_contract_test", %{scope: scope})
    |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{project_id}", payload)
  end
end
