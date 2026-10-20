defmodule CodeMySpecWeb.Operations do
  @moduledoc """
  The Operations console: running the app once it is live — chats, mail,
  mailboxes, users and content — each its own page, framed with one sidebar.
  """

  use CodeMySpecWeb, :html

  alias CodeMySpecWeb.ConsoleFrame

  @doc "Frames a page in the Operations console; with no project, the page alone."
  attr :project_id, :any, required: true
  attr :active, :atom, required: true, doc: "the sidebar entry to mark"
  attr :current_scope, :any, required: true
  slot :inner_block, required: true

  def frame(%{project_id: nil} = assigns) do
    ~H"""
    {render_slot(@inner_block)}
    """
  end

  def frame(assigns) do
    assigns = assign(assigns, :mailboxes?, can_manage_mailboxes?(assigns.current_scope))

    ~H"""
    <ConsoleFrame.frame>
      <:sidebar>
        <ul data-test="operations-sidebar" class="menu bg-base-200 min-h-full w-56 p-4 gap-1">
          <li class="menu-title text-base text-base-content">Operations</li>
          <.entry project_id={@project_id} active={@active} key={:chats} path="inbox">Chats</.entry>
          <.entry project_id={@project_id} active={@active} key={:mail} path="mail">Mail</.entry>
          <.entry
            :if={@mailboxes?}
            project_id={@project_id}
            active={@active}
            key={:mailboxes}
            path="mailboxes"
          >
            Mailboxes
          </.entry>
          <.entry project_id={@project_id} active={@active} key={:users} path="users">Users</.entry>
          <.entry project_id={@project_id} active={@active} key={:content} path="content">
            Content
          </.entry>
        </ul>
      </:sidebar>
      {render_slot(@inner_block)}
    </ConsoleFrame.frame>
    """
  end

  attr :project_id, :string, required: true
  attr :active, :atom, required: true
  attr :key, :atom, required: true
  attr :path, :string, required: true
  slot :inner_block, required: true

  defp entry(assigns) do
    ~H"""
    <li>
      <.link
        navigate={"/app/projects/#{@project_id}/#{@path}"}
        data-test={"operations-nav-#{@key}"}
        class={@key == @active && "menu-active"}
      >
        {render_slot(@inner_block)}
      </.link>
    </li>
    """
  end

  @doc "Whether this scope may manage the project's mailboxes."
  def can_manage_mailboxes?(%{active_account_id: account_id} = scope) when is_binary(account_id),
    do: CodeMySpec.Mail.can_administer?(scope)

  def can_manage_mailboxes?(_scope), do: false
end
