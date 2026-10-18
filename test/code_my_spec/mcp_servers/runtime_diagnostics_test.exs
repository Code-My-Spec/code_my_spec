defmodule CodeMySpec.McpServers.RuntimeDiagnosticsTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.BootVersion
  alias CodeMySpec.McpServers.MainAgent.Tools.RuntimeDiagnostics

  defp agent(scope, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        working_copy: "/tmp/a-copy",
        working_copy_id: scope.active_working_copy_id,
        role: role,
        status: :running,
        tools: ["stale_grant"]
      })

    agent
  end

  defp call(scope, caller, target) do
    frame = %Frame{assigns: %{current_scope: scope, agent_id: caller.id}}
    {:reply, response, ^frame} = RuntimeDiagnostics.execute(%{agent_id: target.id}, frame)
    protocol = Response.to_protocol(response)
    {response.isError, hd(protocol["content"])["text"]}
  end

  test "main sees current QA grants and actual wrapper discovery without credentials" do
    scope = full_scope_fixture()
    main = agent(scope, :main)
    qa = agent(scope, :qa)
    {false, text} = call(scope, main, qa)
    result = Jason.decode!(text)

    assert result["agent"]["browser_capability"]
    assert "browser" in result["agent"]["effective_grants"]
    refute "stale_grant" in result["agent"]["effective_grants"]
    assert hd(result["agent"]["browser_wrapper_discovery"])["text"] =~ "You carry it directly"
    assert result["serving"]["os_pid"] == System.pid()
    assert map_size(result["loaded_modules"]) == 3

    assert Map.keys(result["agent"]) |> Enum.sort() ==
             Enum.sort(
               ~w(id role working_copy_id effective_grants browser_capability browser_wrapper_discovery)
             )
  end

  # `ToolIndex.carried/1` answers "You carry it directly" for every agent
  # whose id resolves, regardless of role -- the direct surface is the same
  # for every in-BEAM agent. `browser_capability` is the field that actually
  # distinguishes roles; the two are reported separately exactly so a role
  # like product, which does not browse, is told it carries the wrapper while
  # still being told, correctly, that it has no browser capability.
  test "a role without browser capability is distinguished from QA" do
    scope = full_scope_fixture()
    {false, text} = call(scope, agent(scope, :main), agent(scope, :product))
    result = Jason.decode!(text)
    refute result["agent"]["browser_capability"]
    assert hd(result["agent"]["browser_wrapper_discovery"])["text"] =~ "You carry it directly"
  end

  test "coding cannot invoke the main diagnostic" do
    scope = full_scope_fixture()
    {true, text} = call(scope, agent(scope, :coding), agent(scope, :qa))
    assert text =~ "main_only"
  end

  test "a target in another project is not exposed" do
    scope = full_scope_fixture()
    other = full_scope_fixture()
    {true, text} = call(scope, agent(scope, :main), agent(other, :qa))
    assert text =~ "not_found"
  end

  defp restore_boot(key, :missing), do: :persistent_term.erase(key)
  defp restore_boot(key, previous), do: :persistent_term.put(key, previous)

  test "checkout movement does not replace the boot revision" do
    key = {BootVersion, :boot}
    previous = :persistent_term.get(key, :missing)

    on_exit(fn -> restore_boot(key, previous) end)

    :persistent_term.put(key, {File.cwd!(), "recorded-boot-revision"})
    snapshot = BootVersion.runtime_snapshot()
    assert snapshot.boot_revision == "recorded-boot-revision"
    assert snapshot.checkout_head != snapshot.boot_revision
    assert snapshot.revision_basis =~ "hot-reloaded"
    assert {:ok, _, _} = DateTime.from_iso8601(snapshot.vm_started_at)
  end
end
