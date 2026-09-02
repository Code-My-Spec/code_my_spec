defmodule CodeMySpecSpex.Story1038.Criterion3017Spex do
  @moduledoc """
  Story 1038 — The agent I run gets its tools without paying for a catalogue.
  Criterion 3017 — A browser is no extra tools, not eighty-five.

  Rule: A third-party MCP server arrives as one tool, not as its list.

  Our own ninety-eight are the reason this story exists, and they are not the
  worst of it. A QA agent also carries a browser, and asking vibium's own MCP
  server what it offers returns **eighty-five** tools — every one of them a
  schema read on every turn to be told what a click is.

  ## Rewritten once, and a correction inside that

  This said "one tool, not eighty-five", and I changed the number to twenty-nine
  on the strength of `plugins/claude/agents/qa.md`, which grants twenty-nine
  `mcp__vibium__browser_*` tools. That was the wrong source: twenty-nine is what
  the plugin hands a QA agent, eighty-five is what the browser has, and the
  criterion was always about the second. `vibium mcp` answers `tools/list` with
  eighty-five, which is where this number comes from and where to re-check it.

  What did need rewriting is the answer. John's design mounts a third-party
  server the way ours is mounted: `vibium mcp` speaks JSON-RPC over stdio to the
  harness, and its tools join a catalog a script reaches rather than going onto
  the agent.

  ## The one tool, which used to be none

  That catalog was `run_script`'s, and for a while the agent carried *nothing*
  extra for the browser — the rule satisfied by arriving as none. It is now its
  own sandbox with its own entry, `run_browser_script`, because the two kinds of
  tool cannot share a wall clock: `browser_wait_for_text` waits by design, on a
  duration the caller passes, while `list_stories` is a database read. Sharing
  one deadline meant a browser call was given a hardcoded thirty seconds inside
  a script whose own limit was also thirty, so they expired together.

  So this asserts reach at a stated price: none of the browser's eighty-five
  tools are on the agent, and exactly one tool is, which is what the rule asks
  for rather than the better thing the first implementation happened to manage.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A third-party MCP server arrives as one tool, not as its list" do
    scenario "A browser is no extra tools, not twenty-nine" do
      given_ "a machine whose browser offers its tools", context do
        offered = fake_browser(context)

        {:ok, Map.put(context, :offered, offered)}
      end

      when_ "an agent is started on it", context do
        id = running_agent(context)

        {:ok,
         context
         |> Map.put(:agent_id, id)
         |> Map.put(:carried, id |> Fixtures.agent_tools() |> Enum.map(& &1.name()))}
      end

      then_ "it carries one tool for them, not their list", context do
        carried = MapSet.new(context.carried)
        browsery = Enum.filter(context.offered, &MapSet.member?(carried, &1))

        assert browsery == [],
               "the browser arrived as #{length(browsery)} tools on the agent. " <>
                 "Eighty-five schemas read every turn to be told what a click is, " <>
                 "on top of our own ninety-eight, is the catalogue this story " <>
                 "exists to stop. Got: #{inspect(browsery)}"

        # One, where this used to assert none.
        #
        # The rule is "arrives as one tool, not as its list", and the first
        # implementation beat it: the browser joined the catalog `run_script`
        # already reached, so it arrived as nothing at all. That is no longer
        # true, and the reason is a deadline rather than a regression — the
        # browser's tools wait by design where the project's answer in
        # milliseconds, and one wall clock cannot be right for both. They have
        # their own sandbox now, entered through `run_browser_script`, which the
        # caller gives a timeout.
        #
        # John's decision, made knowing the price: "Unless we can get the vibium
        # tools in a separate sandbox with different timeout properties I think
        # it just needs to come out of our sandbox since they have such
        # different properties." One schema against eighty-five is the trade,
        # and asserting on it is what stops the next one being free.
        assert "run_browser_script" in context.carried,
               "the browser's sandbox has no way in, so the tools the agent did " <>
                 "not carry are unreachable rather than merely uncounted."

        {:ok, context}
      end

      then_ "and can reach all of them through the one it already had", context do
        listed = Fixtures.tool_docs(%{}, agent_context(context))

        assert {:ok, body} = listed

        for name <- context.offered do
          assert body =~ name,
                 "#{name} is on this machine's browser and the agent cannot find it, " <>
                   "so the tools it did not carry are unreachable rather than merely " <>
                   "uncounted — which is a smaller product, not a cheaper way in."
        end

        {:ok, context}
      end
    end
  end
end
