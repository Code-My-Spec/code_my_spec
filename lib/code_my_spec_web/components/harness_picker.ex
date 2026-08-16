defmodule CodeMySpecWeb.HarnessPicker do
  @moduledoc """
  Chooses which working copy a page is describing.

  Files and problems belong to the checkout that observed them, so a page has to
  say which one it is showing. It defaults to the most recently active — no
  configuration, and right for a checkout nobody thought to classify — and this
  is how the operator reaches the others. Criterion 739.

  Hidden when a project has one working copy, which is every project until
  somebody runs a second harness. A picker offering a single choice is furniture.

  The choice travels in the URL rather than in socket state so a link to "the
  files as the sprite sees them" is a link somebody can send.

  ## Why it is bounded

  Every harness ever registered against the project is a row, and a row is
  forever: this project has 90, of which 3 were seen in the last day and 46 are
  `/T/cms_harness_<pid>` temp directories left behind by test runs. Rendered as
  a flat row of buttons that is most of a screen, and it grows every time
  anything registers.

  So the few most recent are buttons and the rest sit behind a dropdown. Three,
  because the checkouts an operator switches between are the ones they worked in
  today, and on this project that is exactly three.

  The active copy is always among the buttons even when it is not recent — a
  picker that cannot show which one you are reading is worse than one that is
  too long.

  The count on the dropdown is deliberate. "+87" says the list is wrong rather
  than hiding that it is, and the fix for that is liveness on the harness
  itself (story 892), not a shorter picker.
  """

  use Phoenix.Component

  alias CodeMySpec.Harnesses

  # Enough for the checkouts in play, short enough not to wrap on a phone.
  @visible 3

  attr :harnesses, :list, required: true
  attr :active_id, :string, default: nil
  attr :path_fun, :any, required: true, doc: "fn harness_id -> path"

  def harness_picker(assigns) do
    {shown, rest} = split(assigns.harnesses, assigns.active_id)
    assigns = assigns |> assign(:shown, shown) |> assign(:rest, rest)

    ~H"""
    <div
      :if={length(@harnesses) > 1}
      class="flex flex-wrap items-center gap-2 mb-4"
      data-test="harness-picker"
    >
      <span class="text-sm text-base-content/60">Working copy:</span>
      <.link
        :for={harness <- @shown}
        patch={@path_fun.(harness.id)}
        data-test={"harness-" <> harness.id}
        title={harness.label}
        class={"btn btn-xs " <> if(harness.id == @active_id, do: "btn-primary", else: "btn-ghost")}
      >
        {short_label(harness)}
      </.link>

      <div :if={@rest != []} class="dropdown dropdown-end" data-test="harness-more">
        <div tabindex="0" role="button" class="btn btn-xs btn-ghost" title="Other working copies">
          +{length(@rest)}
        </div>
        <%!-- Bounded and scrollable: the overflow is 87 entries on this project,
              and a dropdown running off the screen is the same problem one layer
              down. --%>
        <ul
          tabindex="0"
          class="dropdown-content menu z-10 max-h-80 w-72 flex-nowrap overflow-y-auto rounded-box bg-base-200 p-2 shadow"
        >
          <li :for={harness <- @rest}>
            <.link
              patch={@path_fun.(harness.id)}
              data-test={"harness-" <> harness.id}
              title={harness.label}
            >
              <span class="truncate">{short_label(harness)}</span>
            </.link>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  # The list arrives ordered by last-seen, so the head is the recent work. The
  # active copy is pulled forward when it is not already there — otherwise
  # selecting an old checkout hides the very button saying you selected it.
  defp split(harnesses, active_id) do
    {shown, rest} = Enum.split(harnesses, @visible)

    case Enum.find(rest, &(&1.id == active_id)) do
      nil ->
        {shown, rest}

      active ->
        {Enum.take(shown, @visible - 1) ++ [active],
         Enum.drop(shown, @visible - 1) ++ List.delete(rest, active)}
    end
  end

  @doc """
  The scope a page should read with, given a requested working copy.

  An id that names no harness on this project falls back to the default rather
  than erroring — a stale bookmark or a checkout somebody deleted should show
  the current one, not a stack trace.
  """
  @spec scope_for(CodeMySpec.Users.Scope.t(), String.t() | nil) :: CodeMySpec.Users.Scope.t()
  def scope_for(scope, nil), do: Harnesses.viewing(scope)

  def scope_for(scope, harness_id) do
    case Enum.find(Harnesses.list_harnesses(scope), &(&1.id == harness_id)) do
      nil -> Harnesses.viewing(scope)
      harness -> %{scope | active_harness_id: harness.id}
    end
  end

  # The label is "the harness at <root> on <host>". The root's last segment is
  # what distinguishes two checkouts of one project, so that is what the button
  # shows; the whole string is the title attribute.
  defp short_label(%{label: label}) when is_binary(label) do
    case Regex.run(~r{at\s+(\S+)}, label) do
      [_, path] -> path |> String.split("/") |> List.last()
      _ -> label
    end
  end

  defp short_label(_harness), do: "unnamed"
end
