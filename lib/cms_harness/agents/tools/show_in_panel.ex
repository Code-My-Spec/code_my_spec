defmodule CmsHarness.Agents.Tools.ShowInPanel do
  @moduledoc """
  Put something in front of the person watching, carried directly.

  `CodeMode.Catalog` excludes it with "it puts something in front of a person,
  who is not watching a script" — true of scripts, and the engine did not carry
  it, so an agent had no way to steer the screen of the person reading its
  conversation.

  The panel it drives is the middle pane of the agent conversation screen, and
  `ScreenState` records the change as an *offer* rather than applying it: a wide
  screen takes it immediately, a phone marks it and takes it when the person
  taps. So calling this is cheap and never evicts what somebody is reading.

  Task-driven panel changes are designed and not built — see
  `.code_my_spec/internal/dynamic_panel_design.md`. When they land this stays,
  because a task implies a default and not everything worth showing.
  """

  use CmsHarness.Agents.Tools.Direct,
    name: "show_in_panel",
    nothing_to: "no screen it can reach"

  @impl true
  def description do
    """
    Show something in the panel beside your conversation, so the person reading
    it is looking at what you are working on.

    Call it when you start on a story — they should not have to go and find it.
    It never interrupts: on a narrow screen it waits to be tapped.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        view: %{
          type: "string",
          enum: ["stories", "story"],
          description: ~s(What to show: "stories" for the project's list, "story" for one.)
        },
        story_id: %{
          type: "integer",
          description: ~s(Which story, when view is "story". Ignored otherwise.)
        }
      },
      required: ["view"]
    }
  end
end
