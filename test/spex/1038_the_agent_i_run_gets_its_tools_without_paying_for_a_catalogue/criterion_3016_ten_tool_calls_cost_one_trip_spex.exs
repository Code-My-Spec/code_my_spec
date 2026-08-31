defmodule CodeMySpecSpex.Story1038.Criterion3016Spex do
  @moduledoc """
  Story 1038 — The agent I run gets its tools without paying for a catalogue.
  Criterion 3016 — Ten tool calls cost one trip.

  Rule: A script runs beside the data, not beside the agent.

  The other half of what code mode buys. Two schemas instead of ninety-eight is
  the context saving; this is the latency one. A loop that calls ten tools the
  ordinary way is ten model turns and ten round trips, and every one of them
  waits for the machine.

  Measured as one invocation returning ten answers, because that is what "one
  trip" means from the side that pays for it: the agent asked once. Counting
  packets would be measuring the transport rather than the claim.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  
  setup :register_log_in_setup_account
  setup :setup_active_project

  # Counts its own calls and says so, so the assertion can tell "ten ran" from
  # "one ran and returned a list".
  @script """
  local calls = 0
  for _ = 1, 10 do
    list_story_titles({})
    calls = calls + 1
  end
  return "calls in one invocation: " .. calls
  """

  spex "A script runs beside the data, not beside the agent" do
    scenario "Ten tool calls cost one trip" do
      given_ "a script that calls ten tools", context do
        {:ok, context |> Map.put(:agent_id, running_agent(context)) |> Map.put(:script, @script)}
      end

      when_ "the agent runs it", context do
        reply = Fixtures.run_script(context.script, agent_context(context))

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "the machine and the server exchange one round trip, not ten", context do
        assert {:ok, body} = context.reply,
               "ten calls in one script did not run at all. Got: #{inspect(context.reply)}"

        assert body =~ "calls in one invocation: 10",
               "one invocation of run_script did not make ten tool calls, so the " <>
                 "loop is not running beside the data. Ten calls the ordinary way " <>
                 "are ten model turns and ten waits on the machine. " <>
                 "Got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end
