defmodule CodeMySpec.Agents.TheToolIndexAdvertisesOnlyToolsThatWorkTest do
  @moduledoc """
  2c572a27. Main's prompt listed `await_analysis` under the tools a script can
  call; it was a tombstone for a removed tool, so a bisect plan was built on a
  tool that does not exist. What an agent is told it can reach is generated from
  the tools that exist, per role: a tombstone is never advertised (it still
  answers a stale session), and every name listed to a role is a tool that role
  carries and that resolves.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Agents.ToolIndex
  alias CodeMySpec.McpServers.ToolRegistry
  alias CodeMySpec.ToolLibrary

  setup do
    %{registry: ToolRegistry.registry()}
  end

  defp agent(%{role: role, tools: :all}), do: %Agent{role: role, tools: nil}
  defp agent(%{role: role, tools: tools}), do: %Agent{role: role, tools: tools}

  test "await_analysis is a tombstone: callable, and named by no role's index", ctx do
    assert "await_analysis" in ToolLibrary.tombstoned()
    assert {:ok, _tool} = ToolLibrary.fetch("await_analysis")

    for profile <- RoleProfile.all() do
      index = ToolIndex.reach(agent(profile), ctx.registry)

      refute "await_analysis" in index["scriptable"],
             "#{profile.role} is told it can call a tool that was removed"

      refute "await_analysis" in ToolIndex.carried(ctx.registry)
    end
  end

  test "every name a role is told it can script resolves and is one it carries", ctx do
    known = MapSet.new(ctx.registry.scriptable, & &1.name)

    for profile <- RoleProfile.all() do
      names = ToolIndex.reach(agent(profile), ctx.registry)["scriptable"]

      for name <- names do
        assert MapSet.member?(known, name), "#{profile.role} is told about unknown tool #{name}"

        assert RoleProfile.carries?(profile.role, name),
               "#{profile.role} is told it can call #{name}, which it does not carry"
      end
    end
  end

  test "analysis history is scriptable for coding, QA and Main", ctx do
    for role <- [:coding, :qa, :main] do
      profile = RoleProfile.get(role)
      names = ToolIndex.reach(agent(profile), ctx.registry)["scriptable"]

      assert "get_analysis_history" in names, "#{role} cannot read retained analyzer failures"
      assert RoleProfile.carries?(role, "get_analysis_history")
    end
  end

  test "every direct name resolves to a registered tool", ctx do
    direct = MapSet.new(ctx.registry.direct, & &1.name)

    for name <- ToolIndex.carried(ctx.registry) do
      assert MapSet.member?(direct, name)
      refute name in ToolLibrary.tombstoned()
    end
  end
end
