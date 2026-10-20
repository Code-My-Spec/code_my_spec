defmodule CodeMySpecWeb.FilterComponents do
  @moduledoc """
  Filter controls for a list page's header: a dropdown of checkboxes for a set
  and one of radios for a single choice, both as outlined buttons that keep
  their label on one line and say what is chosen in a word or two.
  """
  use CodeMySpecWeb, :html

  @doc "A set to filter by. Sends `name[]`, with an empty value so clearing every box still sends."
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true
  attr :chosen, :list, required: true

  # A dropdown of checkboxes. The empty hidden value is what lets every box be
  # cleared: without it an all-unchecked form sends nothing, and nothing reads
  # as the default.
  def multi_select(assigns) do
    ~H"""
    <div class="dropdown dropdown-end" data-test={"filter-#{@name}"}>
      <div
        tabindex="0"
        role="button"
        class="btn btn-sm btn-outline shrink-0 whitespace-nowrap font-normal"
      >
        {summary(@chosen, @options, @label)}
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu z-10 mt-1 w-44 rounded-box border border-base-300 bg-base-100 p-2 shadow"
      >
        <input type="hidden" name={"#{@name}[]"} value="" />
        <li :for={option <- @options}>
          <label class="flex items-center gap-2">
            <input
              type="checkbox"
              name={"#{@name}[]"}
              value={option}
              checked={option in @chosen}
              class="checkbox checkbox-xs"
            />
            {String.capitalize(option)}
          </label>
        </li>
      </ul>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :options, :list, required: true
  attr :chosen, :string, required: true
  attr :label, :any, required: true, doc: "option -> its name"

  @doc "One choice of several, styled as the multi-select."
  def single_select(assigns) do
    ~H"""
    <div class="dropdown dropdown-end" data-test={"filter-#{@name}"}>
      <div
        tabindex="0"
        role="button"
        class="btn btn-sm btn-outline shrink-0 whitespace-nowrap font-normal"
      >
        {@label.(@chosen)}
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu z-10 mt-1 w-44 rounded-box border border-base-300 bg-base-100 p-2 shadow"
      >
        <li :for={option <- @options}>
          <label class="flex items-center gap-2">
            <input
              type="radio"
              name={@name}
              value={option}
              checked={option == @chosen}
              class="radio radio-xs"
            />
            {@label.(option)}
          </label>
        </li>
      </ul>
    </div>
    """
  end

  # Short enough for the header: one choice by name, several as the first and
  # a count. `label` stands in for the field when the choice says nothing.
  defp summary(chosen, options, label) when length(chosen) == length(options),
    do: "All #{String.downcase(label)}"

  defp summary([], _options, label), do: "No #{String.downcase(label)}"
  defp summary([one], _options, _label), do: String.capitalize(one)

  defp summary([first | rest], _options, _label),
    do: "#{String.capitalize(first)} +#{length(rest)}"
end
