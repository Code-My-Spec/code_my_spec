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

  Nothing had failed. That string appears nowhere in this codebase or any
  dependency — it is the model's own words, written after reading
  `available_tools` and not believing what it found. No exception, no log line,
  a schema-valid response, and a run indistinguishable from an agent that
  considered its work and declined it.

  Refusing to improvise is exactly what `OperatingRules` asks for, so the agent
  was obeying its instructions. It was simply wrong about the premise, and no
  part of the prompt had told it how its tools arrive.

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

  Your tools arrive with each request as `available_tools`. That list is the
  whole of what you can call, and it is complete — the index above names the
  same tools.

  To call one, return it as a tool call. Do not describe the call in prose and
  do not write out what you would have run; nothing executes text.

  **If a tool seems to be missing, look in `available_tools` before concluding
  anything.** Not finding a name there in one reading is not evidence it is
  gone, and this is the one thing agents on this engine get wrong: reporting
  `get_next_requirement` or `run_script` as unavailable and stopping, when both
  were present and no call had been made or refused.

  Report a tool as broken only when you actually called it and it actually
  answered with an error. A tool you did not call has not failed.
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
