defmodule CodeMySpecWeb.ConsoleFrame do
  @moduledoc """
  A console's frame: a sidebar beside the section being shown, a drawer on a
  phone. The DevOps and Operations consoles each bring their own sidebar.
  """

  use CodeMySpecWeb, :html

  slot :sidebar, required: true
  slot :toolbar, doc: "beside the phone's menu button"
  slot :inner_block, required: true

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
        {render_slot(@sidebar)}
      </div>
    </div>
    """
  end
end
