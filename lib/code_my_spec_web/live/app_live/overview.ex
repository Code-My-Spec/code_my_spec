defmodule CodeMySpecWeb.AppLive.Overview do
  use CodeMySpecWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Overview")}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div>
        <h1 class="text-3xl font-bold mb-6">Overview</h1>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div class="stat bg-base-200 rounded-lg">
            <div class="stat-title">Projects</div>
            <div class="stat-value">0</div>
          </div>
          <div class="stat bg-base-200 rounded-lg">
            <div class="stat-title">Stories</div>
            <div class="stat-value">0</div>
          </div>
          <div class="stat bg-base-200 rounded-lg">
            <div class="stat-title">Components</div>
            <div class="stat-value">0</div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
