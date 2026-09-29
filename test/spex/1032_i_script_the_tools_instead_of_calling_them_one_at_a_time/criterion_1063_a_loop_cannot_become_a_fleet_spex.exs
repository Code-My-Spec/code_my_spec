defmodule CodeMySpecSpex.Story1032.Criterion2987Spex do
  @moduledoc """
  Story 1032 — I script the tools instead of calling them one at a time
  Criterion 2987 — A loop cannot become a fleet

  `start_agent` is scriptable (main only among agents), so a loop can call it.
  The seat bounds it: once an agent holds a role on a copy, starting that role
  there again is refused. A refusal comes back to the script as `nil, err`, so
  the loop runs to the end and every call after the first is refused.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript
  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I script the tools instead of calling them one at a time", criterion: 1063 do
    scenario "A loop cannot become a fleet" do
      given_ "the agent is connected to its project, with a provider to start agents on",
             context do
        # No surface connects a provider's subscription; it is external state.
        {:ok, _integration} = Fixtures.connect_provider(context.scope, :openai)

        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      when_ "the script loops start_agent for one role twenty times", context do
        script = ~S"""
        local started, refused = 0, {}
        for i = 1, 20 do
          local agent, err = start_agent({ role = "coding", engine = "alloy",
                                           provider = "openai-codex", working_copy = "copy-a" })
          if agent then started = started + 1 else refused[#refused + 1] = err.message end
        end
        return { started = started, refused = refused }
        """

        {:reply, response, _frame} = RunScript.execute(%{script: script}, context.frame)

        {:reply, listing, _frame} =
          RunScript.execute(%{script: ~S[return list_agents({})]}, context.frame)

        {:ok, context |> Map.put(:response, response) |> Map.put(:listing, listing)}
      end

      then_ "the first call starts the agent and the other nineteen are refused", context do
        text = response_text(context.response)

        refute context.response.isError, "the script itself failed. Got:\n" <> text

        assert text =~ ~r/"?started"?\s*[:=]\s*1\b/,
               "a loop of twenty start_agent calls for one seat did not start exactly one. Got:\n" <>
                 text

        assert length(Regex.scan(~r/already has a coding agent/, text)) == 19,
               "expected nineteen refusals naming the seat as taken. Got:\n" <> text

        {:ok, context}
      end

      then_ "and exactly one agent was started", context do
        text = response_text(context.listing)

        assert length(Regex.scan(~r/copy-a/, text)) == 1,
               "expected one agent on copy-a, one per seat. Got:\n" <> text

        {:ok, context}
      end
    end
  end
end
