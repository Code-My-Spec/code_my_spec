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

  Every response you produce is one JSON object. Putting a tool in `tool_calls`
  is how you use it: the harness runs it and sends the result in your next
  request. Text does not run.

  `available_tools` arrives with each request — the names you may put in
  `tool_calls`, each with its argument schema.

  ### A tool from the "Called directly" list

      {"stop_reason": "tool_use",
       "text": "",
       "tool_calls": [{"call_id": "1",
                       "name": "get_next_requirement",
                       "arguments": {}}]}

  ### A tool from the "Called from inside `run_script`" list

  Those names are Lua functions, not tool names, and have no entry in
  `available_tools`. Name `run_script` and write the call into its `script`.
  Each takes one table and returns a value and an error:

      {"stop_reason": "tool_use",
       "text": "",
       "tool_calls": [{"call_id": "1",
                       "name": "run_script",
                       "arguments": {"script": "local issue, err = create_issue({ scope = 'framework', severity = 'warning', title = 'short title', description = 'what happened' }); return { issue = issue, err = err }"}}]}

  Single quotes in the script: it is already a JSON string, so nothing is
  escaped twice. Several calls is ordinary Lua — assign each result, return a
  table of them.

  ### The arguments a Lua function takes

      {"stop_reason": "tool_use",
       "text": "",
       "tool_calls": [{"call_id": "1",
                       "name": "tool_docs",
                       "arguments": {"names": ["create_issue"]}}]}

  Ask before your first script rather than composing one from memory.

  ### Answering without calling anything

      {"stop_reason": "end_turn",
       "text": "what you want to say",
       "tool_calls": []}

  ### Check before you return

  A tool's result reaches you in the next request, never in the response that
  calls it. So do not write that a tool returned, failed, or succeeded unless
  that outcome is in a result you were actually sent earlier. Read back every
  sentence that has a tool saying or returning something: if there is no result
  in the conversation to point at, it did not happen — delete the sentence, put
  the tool in `tool_calls`, and return.

  `tool_calls: []` ends the turn having run nothing.
  """

  @doc """
  The brief for this provider, or `nil` when there is nothing to say.

  `nil` for a provider whose tool calling is native and needs no explanation —
  an agent told something vague about its own runtime is worse off than one
  told nothing, the same reason `RoleBrief.for/1` gives.
  """
  @spec for(String.t() | atom() | nil) :: String.t() | nil
  def for("claude-code") do
    # Off by default, and the text kept for comparison.
    #
    # `LaunchRequest` seeds the agent's history with a direct call and a nested
    # one, both real, so the transcript opens having already done each shape.
    # Measured 2026-09-21 on the two criteria that fabricated tool failures
    # most: 3535 went from 7 in 10 at its best under prose to 10 in 10 with no
    # prose at all, and 3545 from 3 in 10 with this text to 8 in 10 without it.
    #
    # The text is not neutral. It cannot describe the format without naming
    # what a failure looks like, and naming that is what the agents echoed back
    # as live results. A demonstration says the same thing and gives them
    # nothing to quote. `CMS_PROVIDER_BRIEF=1` puts it back.
    if System.get_env("CMS_PROVIDER_BRIEF") in ~w(1 true),
      do: String.trim(@claude_code),
      else: nil
  end

  def for(_provider), do: nil
end
