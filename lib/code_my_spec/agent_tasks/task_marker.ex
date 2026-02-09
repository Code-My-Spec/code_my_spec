defmodule CodeMySpec.AgentTasks.TaskMarker do
  @moduledoc """
  Embeds and extracts structured markers in task prompts so subagent
  transcripts are self-identifying.

  Marker format (HTML comment):
    <!-- cms:task type="ComponentTest" component="MetricFlow.Accounts.User" -->
  """

  @marker_pattern ~r/<!-- cms:task type="([^"]+)" component="([^"]+)" -->/

  def build(task_type, component_module_name) do
    ~s(<!-- cms:task type="#{task_type}" component="#{component_module_name}" -->)
  end

  def extract(text) when is_binary(text) do
    case Regex.run(@marker_pattern, text) do
      [_, type, component] -> {:ok, %{type: type, component: component}}
      nil -> :none
    end
  end
end
