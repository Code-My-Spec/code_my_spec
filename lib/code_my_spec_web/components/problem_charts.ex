defmodule CodeMySpecWeb.ProblemCharts do
  @moduledoc """
  Problems as stacked bars for the `EChart` hook: how many each working copy
  holds, and where in one copy they sit. Stacked by source, in one fixed order
  and colour per source, so the two charts read the same way.
  """
  use CodeMySpecWeb, :html

  alias CodeMySpec.WorkingCopies

  @sources ~w(compiler credo exunit spex qa_validation)
  @colors %{
    "compiler" => "#ef4444",
    "credo" => "#f59e0b",
    "exunit" => "#8b5cf6",
    "spex" => "#3b82f6",
    "qa_validation" => "#10b981"
  }

  @doc """
  One bar per working copy. Clicking a bar pushes `pick_event` with the
  copy's id. Copies with no problems are left out; the selected one is marked.
  """
  attr :counts, :list, required: true, doc: "`[{working_copy_id, source, count}]`"
  attr :harnesses, :list, required: true
  attr :selected_id, :string, default: nil
  attr :pick_event, :string, default: nil

  def by_copy(assigns) do
    names = Map.new(assigns.harnesses, &{&1.id, WorkingCopies.display_name(&1)})

    rows =
      assigns.counts
      |> Enum.filter(fn {id, _source, _count} -> Map.has_key?(names, id) end)
      |> rows()

    option =
      rows
      |> bars(fn id -> mark(names[id], id == assigns.selected_id) end)
      |> Map.merge(%{ids: Enum.map(rows, &elem(&1, 0)), pick_event: assigns.pick_event})

    assigns = assign(assigns, option: option, empty?: rows == [])

    ~H"""
    <.chart
      id="problems-by-copy"
      title="Problems per working copy"
      option={@option}
      empty?={@empty?}
      rows={length(@option.categories)}
    />
    """
  end

  @doc "The files with the most problems at one copy."
  attr :counts, :list, required: true, doc: "`[{file_path, source, count}]`"
  attr :copy_name, :string, required: true

  def by_file(assigns) do
    rows = rows(assigns.counts)
    option = bars(rows, &Path.relative/1)
    assigns = assign(assigns, option: option, empty?: rows == [])

    ~H"""
    <.chart
      id="problems-by-file"
      title={"Where #{@copy_name}'s problems are"}
      option={@option}
      empty?={@empty?}
      rows={length(@option.categories)}
    />
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :option, :map, required: true
  attr :empty?, :boolean, required: true
  attr :rows, :integer, required: true

  # Keyed on its data: the hook draws once into an ignored element, so new
  # data is a new element rather than a patch the chart would never see.
  defp chart(assigns) do
    ~H"""
    <section data-test={@id} class="rounded-box border border-base-300 p-4">
      <h2 class="text-sm font-semibold">{@title}</h2>
      <p :if={@empty?} class="py-6 text-center text-sm opacity-60">No problems.</p>
      <div
        :if={!@empty?}
        id={"#{@id}-chart-#{:erlang.phash2(@option)}"}
        phx-hook="EChart"
        phx-update="ignore"
        data-option={Jason.encode!(@option)}
        style={"height: #{80 + @rows * 28}px"}
      >
      </div>
    </section>
    """
  end

  # `[{key, %{source => count}}]`, largest total first.
  defp rows(counts) do
    counts
    |> Enum.group_by(&elem(&1, 0), fn {_key, source, count} -> {source, count} end)
    |> Enum.map(fn {key, by_source} -> {key, Map.new(by_source)} end)
    |> Enum.sort_by(fn {key, by_source} -> {-Enum.sum(Map.values(by_source)), key} end)
  end

  defp bars(rows, label) do
    %{
      kind: "bars",
      categories: Enum.map(rows, fn {key, _} -> label.(key) end),
      stacks:
        for source <- @sources,
            Enum.any?(rows, fn {_key, by_source} -> Map.has_key?(by_source, source) end) do
          %{
            name: source,
            color: @colors[source],
            data: Enum.map(rows, fn {_key, by_source} -> Map.get(by_source, source, 0) end)
          }
        end
    }
  end

  defp mark(name, true), do: "▸ " <> name
  defp mark(name, false), do: name
end
