defmodule CodeMySpecWeb.ConsoleLive.Components.Shell do
  @moduledoc """
  The console's frame: its sidebar beside the section being shown. Shared so a
  page outside `ConsoleLive` (the servers) sits in the console too. With no
  project there is no console to frame it, and the content renders alone.
  """

  use CodeMySpecWeb, :html

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
    <div class="drawer lg:drawer-open drawer-end" data-test="console">
      <input id="console-drawer" type="checkbox" class="drawer-toggle" />

      <div class="drawer-content p-4 lg:p-8 flex flex-col gap-4">
        <div class="flex items-center justify-between gap-4">
          <label for="console-drawer" class="btn btn-ghost drawer-button lg:hidden">
            Menu
          </label>
          {render_slot(@toolbar)}
        </div>

        {render_slot(@inner_block)}
      </div>

      <div class="drawer-side">
        <label for="console-drawer" class="drawer-overlay"></label>
        <Sidebar.sidebar live_action={@active} project_id={@project_id} />
      </div>
    </div>
    """
  end
end
