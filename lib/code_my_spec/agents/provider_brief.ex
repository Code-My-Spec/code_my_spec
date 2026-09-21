defmodule CodeMySpec.Agents.ProviderBrief do
  @moduledoc """
  How this agent's tools actually reach it, given the engine running it.

  Most of the prompt is the same whoever is behind the agent: the loop, the
  project, the role. This is the part that is not — how a tool call physically
  happens differs by provider, and an agent that is wrong about that does not
  fail loudly. It reports that its tools are missing.

  ## The failure this exists to stop

  `claude-code` runs the CLI with `--tools ""`, deliberately: with its own tools
  in hand it would go and do the work itself and hand back a prose summary
  rather than the `tool_use` blocks Alloy's loop executes. So tool calling is
  *emulated* — the provider serialises the tool definitions into the request as
  `available_tools` and asks the model to name one in structured JSON.

  That works, and when it does not work it fails as **wrong output rather than
  as an error**, which the provider's own moduledoc names as its sharpest edge.
  Measured on story 1039's criterion 3539 on 2026-09-20: roughly one first turn
  in four came back with the agent reporting

      Both `get_next_requirement` and `run_script` came back with
      "No such tool available" — they're not reachable in this session even
      though they're the tools I'm instructed to use. I'm not going to
      improvise a workaround around missing core tools.

  Nothing had failed, and the first reading of this was wrong. The string is not
  the model's invention: it is **Claude Code's own**, what the CLI answers when
  a tool is not in its native list. `--tools ""` means that list is empty, so an
  agent that reaches for a tool *directly* — as though it could run one itself —
  is refused by the process it is running in, before Alloy hears anything. No
  `tool_start` is recorded, because no tool call was ever made.

  So the agent is not disbelieving `available_tools`. It is using the wrong
  mechanism: executing instead of naming. The harness executes; the model names
  a tool in `tool_calls` and returns. Measured at n=10 across ten criteria on
  2026-09-21, this was five runs in a hundred.

  Refusing to improvise is exactly what `OperatingRules` asks for, so the agent
  was obeying its instructions. It was simply wrong about how a call happens,
  and no part of the prompt had told it.

  ## Why here rather than in the provider

  The provider already says "each tool call must use a valid tool name from
  `available_tools`" — instructions for *producing* a call. This says where the
  tools are and what to conclude when one seems absent, which is a fact about
  the agent's own runtime. `SystemPrompt.compose/1` carries it in the
  situational section, beside the tool index it is about.

  Resolved server-side, like every other section: `agent.provider` is a column,
  and the harness has no opinion about what an engine does with tools.
  """

  @claude_code """
  ## How you call a tool

  You are the model backend for a harness. **You do not run tools — you name
  them.** The harness runs them and sends you the result on the next turn.

  Your tools arrive with each request as `available_tools`. That list is the
  whole of what you can reach, and the index above names the same tools. To call
  one, put its name and arguments in `tool_calls` and return. Naming it there is
  calling it. Do not describe the call in prose, and do not write out what you
  would have run; nothing executes text.

  **You have no tools of your own.** The process you are running in was started
  with none on purpose, so reaching for one directly — as though you could read
  a file or run a command yourself — fails before the harness ever hears about
  it. What comes back is:

      No such tool available: <name>

  That sentence is not the harness and it is not the tool. It is this process
  telling you that you tried to run something yourself instead of naming it.
  Everything in `available_tools` is reachable; the call simply has to go in
  `tool_calls`. If you see it, put the name in `tool_calls` and return — do not
  report the tool as missing, and do not stop.

  A real tool error looks different. It arrives as the *result* of a call you
  named, on the turn after you named it, and it says `Unknown tool: <name>` or
  carries the tool's own message. Report that, and report it the way the rules
  above say to.

  **A tool you did not name in `tool_calls` has not failed.** It has not been
  called.
  """

  @doc """
  The brief for this provider, or `nil` when there is nothing to say.

  `nil` for a provider whose tool calling is native and needs no explanation —
  an agent told something vague about its own runtime is worse off than one
  told nothing, the same reason `RoleBrief.for/1` gives.
  """
  @spec for(String.t() | atom() | nil) :: String.t() | nil
  def for("claude-code"), do: String.trim(@claude_code)
  def for(_provider), do: nil
end
