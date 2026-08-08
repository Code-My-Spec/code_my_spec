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
  """

  use Phoenix.Component

  alias CodeMySpec.Harnesses

  attr :harnesses, :list, required: true
  attr :active_id, :string, default: nil
  attr :path_fun, :any, required: true, doc: "fn harness_id -> path"

  def harness_picker(assigns) do
    ~H"""
    <div
      :if={length(@harnesses) > 1}
      class="flex flex-wrap items-center gap-2 mb-4"
      data-test="harness-picker"
    >
      <span class="text-sm text-base-content/60">Working copy:</span>
      <.link
        :for={harness <- @harnesses}
        patch={@path_fun.(harness.id)}
        data-test={"harness-" <> harness.id}
        title={harness.label}
        class={"btn btn-xs " <> if(harness.id == @active_id, do: "btn-primary", else: "btn-ghost")}
      >
        {short_label(harness)}
      </.link>
    </div>
    """
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
