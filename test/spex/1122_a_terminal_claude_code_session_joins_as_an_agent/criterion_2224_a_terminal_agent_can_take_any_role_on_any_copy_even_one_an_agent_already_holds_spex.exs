defmodule CodeMySpecSpex.Story1122.Criterion2224Spex do
  @moduledoc """
  Story 1122 — A terminal Claude Code session joins as an agent.
  Criterion 2224 — A terminal agent can take any role on any copy, even one an agent already holds.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A terminal agent can take a role an agent already holds", criterion: 2224 do
    scenario "a terminal agent takes the coding role an Alloy agent holds" do
      given_ "a working copy whose coding role is held by an Alloy agent", context do
        context = HarnessHooks.ensure_live_harness(context)
        {:ok, _} = Fixtures.connect_provider(context.scope, :anthropic)
        # A machine that reports tools, so a start reaches the seat check.
        Fixtures.record_machine_tools(context.scope, ["browser_navigate"])

        coder =
          Fixtures.running_agent(context.scope,
            role: "coding",
            provider: "anthropic",
            working_copy: context.harness.root
          )

        {:ok, Map.put(context, :coder, coder.id)}
      end

      when_ "a terminal agent on that copy takes the coding role", context do
        session = session_id()
        started = start_session(context, session)
        assert {:ok, _} = set_role(context, session, "coding")
        {:ok, Map.put(context, :terminal, started["agent_id"])}
      end

      then_ "it holds the role alongside the Alloy agent", context do
        coders = for %{"role" => "coding", "id" => id} <- agents(context), do: id
        assert Enum.sort(coders) == Enum.sort([context.coder, context.terminal])
        {:ok, context}
      end

      when_ "an Alloy agent is started for the coding role on that copy", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, reply, _frame} =
          StartAgent.execute(
            %{
              role: "coding",
              provider: "anthropic",
              working_copy_id: context.scope.active_working_copy_id
            },
            frame
          )

        result = {reply.isError, response_text(reply)}

        {:ok, Map.put(context, :started, result)}
      end

      then_ "it is still refused, naming the Alloy agent there", context do
        assert {true, refusal} = context.started
        assert refusal =~ "already has a coding agent"
        assert refusal =~ context.coder
        {:ok, context}
      end
    end
  end
end
