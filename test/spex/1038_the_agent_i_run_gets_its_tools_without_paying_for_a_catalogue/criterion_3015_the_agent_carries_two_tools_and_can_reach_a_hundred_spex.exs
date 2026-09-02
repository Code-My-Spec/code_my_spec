defmodule CodeMySpecSpex.Story1038.Criterion3015Spex do
  @moduledoc """
  Story 1038 — The agent I run gets its tools without paying for a catalogue.
  Criterion 3015 — The agent carries two tools and can reach a hundred.

  Rule: Reaching them costs two tools, not a hundred.

  The whole story in one number. Ninety-eight tool schemas is a catalogue the
  agent reads before it can do anything, every turn, and it is the same
  catalogue every turn. Code mode replaces it with two: a way to run a script,
  and a way to look up what the script may call.

  Counted on a running agent rather than on a list in the source, because the
  claim is about what the model is handed. A constant naming two modules is
  true of the constant and says nothing about the agent that was started.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Reaching them costs two tools, not a hundred" do
    scenario "The agent carries two tools and can reach a hundred" do
      given_ "an agent configured with the harness's tools", context do
        {:ok, Map.put(context, :agent_id, running_agent(context))}
      end

      when_ "what it carries is counted", context do
        {:ok, Map.put(context, :tools, Fixtures.agent_tools(context.agent_id))}
      end

      then_ "it is code mode's two, and not the ninety-eight behind them", context do
        names = Enum.map(context.tools, & &1.name())

        assert "run_script" in names,
               "the agent cannot run a script, so the ninety-eight are unreachable " <>
                 "rather than merely uncounted. Got: #{inspect(names)}"

        assert "tool_docs" in names,
               "the agent can run scripts and cannot find out what to call in one, " <>
                 "which is a catalogue it has to be told rather than one it can ask for"

        project_tools = Enum.reject(names, &(&1 in ~w(read write edit bash)))

        # The rule is that the catalogue is a lookup, not a preamble — so what
        # must not be carried is anything a script could have reached. Counting
        # to two said that correctly right up until story 963 needed the agent
        # to hand work over: `start_agent`, `stop_agent` and `assign_subagent`
        # are refused to scripts by `CodeMode.Catalog`, so carrying them adds
        # nothing to the lookup and removing them leaves the agent describing a
        # hand-over it cannot make.
        #
        # Asserted as "nothing carried is scriptable" rather than as a number,
        # which is the invariant the number was standing in for and does not go
        # stale the next time an unscriptable tool is needed.
        scriptable = project_tools -- ~w(start_agent stop_agent assign_subagent)

        # `run_browser_script` is a second door, not a second catalogue. It is
        # the entry to the machine's sandbox, which exists because browser tools
        # wait by design where the project's answer immediately, and one wall
        # clock cannot be right for both — so it is the same kind of thing as
        # `run_script`, and eighty-five browser schemas stay behind it rather
        # than on the agent. Criterion 3017 is where that is asserted.
        assert scriptable == ~w(run_script run_browser_script tool_docs),
               "the agent carries #{inspect(scriptable)} beyond the two ways in and " <>
                 "tool_docs, and every one of those is reachable from a script. Each " <>
                 "is a schema the model reads on every turn to learn something it " <>
                 "could have looked up once."

        {:ok, context}
      end
    end
  end
end
