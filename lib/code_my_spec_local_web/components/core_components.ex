defmodule CodeMySpecLocalWeb.CoreComponents do
  @moduledoc """
  Shared components for the local web interface.

  Mirrors the server-side CoreComponents subset that the ported story /
  persona / Three Amigos LiveViews depend on (`button`, `input`,
  `header`, `list`, `icon`, plus the existing `checklist` and `progress`).
  No gettext on the local side — `translate_error` interpolates the raw
  changeset error message instead.
  """
  use Phoenix.Component

  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  ## Existing local helpers ────────────────────────────────────────────

  attr :evaluated, :list, required: true
  attr :base_path, :string, required: true
  attr :dir_param, :string, required: true

  def checklist(assigns) do
    ~H"""
    <table class="checklist">
      <tr :for={{step, status} <- @evaluated} class={status_css(status)}>
        <td class="icon"><%= status_icon(status) %></td>
        <td>
          <%= case status do %>
            <% :done -> %>
              <%= step.name %>
            <% :blocked -> %>
              <%= step.name %> <span class="tag">blocked</span>
            <% {:not_done, detail} -> %>
              <a href={"#{@base_path}/#{step.id}?dir=#{@dir_param}"}><%= step.name %></a>
              <span class="detail"><%= detail %></span>
          <% end %>
        </td>
      </tr>
    </table>
    """
  end

  attr :done, :integer, required: true
  attr :total, :integer, required: true

  def progress(assigns) do
    pct = if assigns.total > 0, do: round(assigns.done / assigns.total * 100), else: 0
    assigns = assign(assigns, :pct, pct)

    ~H"""
    <div class="subtitle"><%= @done %> of <%= @total %> steps complete</div>
    <div class="progress"><div class="progress-bar" style={"width: #{@pct}%"}></div></div>
    """
  end

  defp status_css(:done), do: "done"
  defp status_css(:blocked), do: "blocked"
  defp status_css({:not_done, _}), do: "actionable"

  defp status_icon(:done), do: Phoenix.HTML.raw("&#10003;")
  defp status_icon(:blocked), do: Phoenix.HTML.raw("&#9744;")
  defp status_icon({:not_done, _}), do: Phoenix.HTML.raw("&#9744;")

  ## Confirm dialog ─────────────────────────────────────────────────────

  @doc """
  Renders a confirmation dialog with Cancel + Confirm buttons.

  Replaces the legacy `data-confirm` pattern, which uses the native
  browser `window.confirm()` dialog. That dialog renders outside the
  DOM, so Vibium / Playwright / Wallaby can't observe or click it —
  every destructive action gated by it is silently un-testable.

  This component renders a DaisyUI `<dialog>` with two regular
  buttons, both clickable by browser automation. Hidden by default;
  trigger it from a sibling button's `phx-click` via
  `show_confirm("the-id")`.

  ## Example

      <button class="btn btn-error" phx-click={show_confirm("delete-foo-\#{@foo.id}")}>
        Delete
      </button>

      <.confirm_dialog
        id={"delete-foo-\#{@foo.id}"}
        title="Delete this foo?"
        message="This cannot be undone."
        confirm_label="Delete"
        on_confirm={JS.push("delete", value: %{id: @foo.id})}
      />

  Stable selectors for tests:
  - The trigger button — whatever the caller renders
  - `[data-role="confirm-cancel"]` inside the dialog
  - `[data-role="confirm-confirm"]` inside the dialog
  """
  attr :id, :string, required: true
  attr :title, :string, default: "Are you sure?"
  attr :message, :string, default: nil
  attr :confirm_label, :string, default: "Confirm"
  attr :cancel_label, :string, default: "Cancel"
  attr :confirm_class, :string, default: "btn btn-error"

  attr :on_confirm, JS,
    required: true,
    doc: "JS command run when the confirm button is clicked"

  def confirm_dialog(assigns) do
    ~H"""
    <dialog id={@id} class="modal" data-role="confirm-dialog">
      <div class="modal-box">
        <h3 class="text-lg font-bold">{@title}</h3>
        <p :if={@message} class="py-4">{@message}</p>
        <div class="modal-action">
          <button
            type="button"
            class="btn"
            data-role="confirm-cancel"
            phx-click={hide_confirm(@id)}
          >
            {@cancel_label}
          </button>
          <button
            type="button"
            class={@confirm_class}
            data-role="confirm-confirm"
            phx-click={@on_confirm |> hide_confirm(@id)}
          >
            {@confirm_label}
          </button>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" aria-label="close" phx-click={hide_confirm(@id)}>close</button>
      </form>
    </dialog>
    """
  end

  @doc "Show a `confirm_dialog` by id (use as a trigger button's `phx-click`)."
  def show_confirm(js \\ %JS{}, id), do: JS.add_class(js, "modal-open", to: "#" <> id)

  defp hide_confirm(js \\ %JS{}, id), do: JS.remove_class(js, "modal-open", to: "#" <> id)

  ## Button ────────────────────────────────────────────────────────────

  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :string, default: "btn btn-primary"
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  ## Input ─────────────────────────────────────────────────────────────

  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :string, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :string, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label>
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}</span>
      </label>
      <textarea
        id={@id}
        name={@name}
        class={[
          @class || "w-full textarea",
          @errors != [] && (@error_class || "textarea-error")
        ]}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  ## Header ────────────────────────────────────────────────────────────

  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex justify-between items-center mb-6", "pb-4"]}>
      <div>
        <h1 class="text-3xl font-bold">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  ## Data list ─────────────────────────────────────────────────────────

  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  ## Heroicon ──────────────────────────────────────────────────────────

  attr :name, :string, required: true
  attr :class, :string, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands ───────────────────────────────────────────────────────

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  ## Error translation ─────────────────────────────────────────────────

  @doc """
  Renders a changeset error message. Local app has no gettext backend, so
  this just interpolates the raw count/values into the message.
  """
  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
