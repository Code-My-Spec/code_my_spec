defmodule CodeMySpec.Hooks.AnalysisAlert do
  @moduledoc """
  The hook's way in to `CodeMySpec.Analysis.Alert`.

  The alert used to live here, because `PostToolUse` was the only thing that
  delivered it. Story 1042 gave it a second transport — an agent running under
  Alloy fires no hooks, so its tool results carry the line instead — and the
  message stopped belonging to either.

  It moved rather than being copied, and Boundary is why. `Hooks` is a top-level
  boundary that depends on `McpServers`, so `McpServers` cannot reference back
  into it; the reference was refused at compile time. That refusal was correct
  and it named the design: the message is analysis's, and a hook is one of two
  ways to hand it over.

  This shim stays so the hook path and every caller reading it are unchanged.
  """

  alias CodeMySpec.Analysis.Alert

  @doc "See `CodeMySpec.Analysis.Alert.check/3`."
  @spec check(CodeMySpec.Users.Scope.t(), String.t() | nil, String.t() | nil) :: String.t() | nil
  defdelegate check(scope, session_id, agent_id \\ nil), to: Alert
end
