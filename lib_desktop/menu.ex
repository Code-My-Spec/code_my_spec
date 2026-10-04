defmodule CodeMySpecDesktop.Menu do
  @moduledoc """
  The menu-bar (tray) icon's menu. Closing the window only hides it, so the
  server and harness keep serving hooks; this is how it comes back, and how
  the app actually quits. Compiled only in the desktop env, which alone has
  the `desktop` dependency.
  """

  use Desktop.Menu

  @impl true
  def mount(menu), do: {:ok, menu}

  @impl true
  def handle_event("open", menu) do
    Desktop.Window.show(CodeMySpecWindow)
    {:noreply, menu}
  end

  def handle_event("quit", menu) do
    Desktop.Window.quit()
    {:noreply, menu}
  end

  @impl true
  def handle_info(_message, menu), do: {:noreply, menu}

  @impl true
  def render(assigns) do
    ~H"""
    <menu>
      <item onclick="open">Open CodeMySpec</item>
      <hr />
      <item onclick="quit">Quit CodeMySpec</item>
    </menu>
    """
  end
end
