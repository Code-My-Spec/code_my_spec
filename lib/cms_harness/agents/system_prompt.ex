defmodule CmsHarness.Agents.SystemPrompt do
  @moduledoc false
  defdelegate compose(parts), to: CodeMySpec.Hooks.AgentBriefing
  defdelegate for_request(request), to: CodeMySpec.Hooks.AgentBriefing
  defdelegate for_request(request, scratch_dir), to: CodeMySpec.Hooks.AgentBriefing
end
