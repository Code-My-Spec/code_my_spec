defmodule CodeMySpecWeb.ConsoleLive.Components.Shell do
  @moduledoc """
  The DevOps console's frame. Shared so a page outside `ConsoleLive` (servers,
  inventory, dev boxes) sits in it too. With no project there is no console to
  frame it, and the content renders alone.
  """

  use CodeMySpecWeb, :html

  alias CodeMySpecWeb.ConsoleFrame
  alias CodeMySpecWeb.ConsoleLive.Components.Sidebar

  attr :project_id, :any, required: true
  attr :active, :atom, required: true, doc: "the sidebar entry to mark"
  slot :toolbar, doc: "beside the phone's menu button"
  slot :inner_block, required: true

  def frame(%{project_id: nil} = assigns) do
    ~H"""
    {render_slot(@inner_block)}
    """
  end

  def frame(assigns) do
    ~H"""
    <ConsoleFrame.frame>
      <:sidebar><Sidebar.sidebar live_action={@active} project_id={@project_id} /></:sidebar>
      <:toolbar>{render_slot(@toolbar)}</:toolbar>
      {render_slot(@inner_block)}
    </ConsoleFrame.frame>
    """
  end
end
