defmodule CodeMySpecWeb.QaComponents do
  @moduledoc """
  A story's QA attempts, at the grains a page needs: counts of recent attempts,
  a chart of attempts over time, a compact row, an attempt's detail,
  and a modal that holds the list and the detail of one picked from it.

  Where a story stands is its latest attempt that was not invalidated — what
  `Qa.list_project_attempts/2` returns by default.
  """
  use CodeMySpecWeb, :html

  @statuses [:pass, :partial, :fail]
  @colors %{pass: "#22c55e", partial: "#eab308", fail: "#ef4444"}

  @doc """
  Attempts submitted in the last `days`, by outcome — the same window the
  attempts chart draws.
  """
  def recent_counts(attempts, days \\ 30) do
    since = Date.add(Date.utc_today(), -(days - 1))
    attempts |> Enum.filter(&(Date.compare(DateTime.to_date(at(&1)), since) != :lt)) |> counts()
  end

  @doc "How many of `attempts` passed, partly passed and failed."
  def counts(attempts) do
    tally = Enum.frequencies_by(attempts, & &1.status)
    Map.new(@statuses, &{&1, Map.get(tally, &1, 0)})
  end

  @doc "Worst first — fail, partial, pass — and newest first within each."
  def worst_first(attempts) do
    attempts
    |> Enum.sort_by(&at(&1), {:desc, DateTime})
    |> Enum.sort_by(&Enum.find_index(Enum.reverse(@statuses), fn s -> s == &1.status end))
  end

  @doc "Pass / partial / fail, as numbers, coloured."
  attr :counts, :map, required: true
  attr :rest, :global

  def counts_mark(assigns) do
    ~H"""
    <button
      type="button"
      data-test="qa-counts"
      data-pass={@counts.pass}
      data-partial={@counts.partial}
      data-fail={@counts.fail}
      data-tip={"QA attempts, last 30 days: #{@counts.pass} passed · #{@counts.partial} partial · #{@counts.fail} failed"}
      class="tooltip tooltip-left flex items-center justify-center gap-0.5 font-mono text-xs tabular-nums"
      {@rest}
    >
      <span class="text-success">{@counts.pass}</span>
      <span class="opacity-30">/</span>
      <span class="text-warning">{@counts.partial}</span>
      <span class="opacity-30">/</span>
      <span class={if @counts.fail > 0, do: "text-error", else: "opacity-50"}>{@counts.fail}</span>
    </button>
    """
  end

  @doc "The ranges the full chart offers."
  def ranges, do: ~w(7d 30d 90d all)

  @doc "What the full chart counts: stories by where each stood, or every attempt."
  def views, do: ~w(stories attempts)

  @doc """
  QA over time, stacked by outcome: every attempt submitted each day, or every
  story by where its latest attempt left it. Compact: attempts over the last
  30 days, no legend, labels or controls. Full: view and range pickers that
  push `event` with `view` or `range`.
  """
  attr :attempts, :list, required: true
  attr :range, :string, default: "30d"
  attr :view, :string, default: "attempts"
  attr :compact, :boolean, default: false
  attr :event, :string, default: nil
  attr :height, :integer, default: 220

  def attempts_chart(assigns) do
    today = Date.utc_today()
    days = days(assigns.attempts, if(assigns.compact, do: "30d", else: assigns.range), today)
    view = if assigns.compact, do: "attempts", else: assigns.view
    counts = day_counts(view, assigns.attempts, days)

    option = %{
      compact: assigns.compact,
      categories: Enum.map(days, &Date.to_iso8601/1),
      series:
        for status <- @statuses do
          %{
            name: Atom.to_string(status),
            type: "line",
            stack: "qa",
            symbol: "none",
            areaStyle: %{},
            y_axis: "count",
            itemStyle: %{color: @colors[status]},
            lineStyle: %{width: 1},
            data: Enum.map(counts, &Map.get(&1, status, 0))
          }
        end
    }

    assigns = assign(assigns, :option, option)

    ~H"""
    <section
      data-test="qa-over-time"
      class={["rounded-box border border-base-300", if(@compact, do: "p-2", else: "p-4")]}
    >
      <div :if={!@compact} class="flex items-center justify-between gap-3">
        <div class="join" data-test="qa-view">
          <button
            :for={view <- views()}
            type="button"
            phx-click={@event}
            phx-value-view={view}
            data-view={view}
            class={["btn btn-xs join-item", view == @view && "btn-active"]}
          >
            {if view == "stories", do: "By story", else: "All attempts"}
          </button>
        </div>
        <div class="join" data-test="qa-range">
          <button
            :for={range <- ranges()}
            type="button"
            phx-click={@event}
            phx-value-range={range}
            data-range={range}
            class={["btn btn-xs join-item", range == @range && "btn-active"]}
          >
            {range}
          </button>
        </div>
      </div>
      <div
        id={"qa-over-time-#{:erlang.phash2(@option)}"}
        phx-hook="EChart"
        phx-update="ignore"
        data-option={Jason.encode!(@option)}
        style={"height: #{@height}px"}
      >
      </div>
    </section>
    """
  end

  @doc "One attempt as a compact row; clicking it pushes `on_pick` with its id."
  attr :attempt, :map, required: true
  attr :on_pick, :string, required: true

  def attempt_row(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@on_pick}
      phx-value-id={@attempt.id}
      data-test="qa-row"
      data-attempt-id={@attempt.id}
      class="flex w-full items-center gap-3 rounded-box px-2 py-2 text-left hover:bg-base-200"
    >
      <span class="min-w-0 flex-1 truncate text-sm">
        <span :if={story_number(@attempt)} class="font-mono opacity-60">#{story_number(@attempt)}</span>
        {story_title(@attempt)}
      </span>
      <span class="hidden shrink-0 text-xs opacity-50 sm:inline">{day(at(@attempt))}</span>
      <span class={["badge badge-sm shrink-0", status_class(@attempt.status)]}>{@attempt.status}</span>
    </button>
    """
  end

  @doc "One attempt in full: its story, outcome, when, each scenario, and its evidence."
  attr :attempt, :map, required: true
  attr :project_id, :string, required: true

  def attempt_detail(assigns) do
    ~H"""
    <div data-test="qa-detail" data-attempt-id={@attempt.id} class="space-y-3">
      <div>
        <p class="text-xs uppercase tracking-wide opacity-60">
          QA attempt · {day(at(@attempt))}
        </p>
        <h2 class="mt-1 pr-8 text-lg font-semibold text-balance">
          <.link
            :if={story_number(@attempt)}
            navigate={~p"/app/projects/#{@project_id}/stories/#{story_number(@attempt)}"}
            class="link link-hover"
          >
            Story {story_number(@attempt)} · {story_title(@attempt)}
          </.link>
          <span :if={!story_number(@attempt)}>{story_title(@attempt)}</span>
        </h2>
        <div class="mt-2 flex flex-wrap items-center gap-2 text-xs">
          <span class={["badge badge-sm", status_class(@attempt.status)]}>{@attempt.status}</span>
          <span :if={@attempt.issue_ids != []} class="opacity-60">
            {length(@attempt.issue_ids)} issue(s) filed
          </span>
        </div>
      </div>

      <ul class="space-y-2">
        <li :for={scenario <- @attempt.scenarios || []} class="rounded-box bg-base-200 p-2 text-sm">
          <div class="flex items-start gap-2">
            <span class={["badge badge-xs mt-0.5 shrink-0", status_class(scenario_status(scenario))]}>
              {scenario_status(scenario)}
            </span>
            <span class="font-medium">{scenario_value(scenario, "name")}</span>
          </div>
          <p :if={scenario_value(scenario, "observation")} class="mt-1 text-xs opacity-70">
            {scenario_value(scenario, "observation")}
          </p>
        </li>
      </ul>

      <div :if={(@attempt.evidence || []) != []}>
        <h3 class="text-xs font-semibold opacity-60">Evidence</h3>
        <ul class="mt-1 flex flex-wrap gap-2">
          <li :for={file <- @attempt.evidence}>
            <a
              href={"/qa_attempts/#{@attempt.id}/evidence/#{scenario_value(file, "name")}"}
              target="_blank"
              rel="noopener"
              class="link text-xs"
            >
              {scenario_value(file, "name")}
            </a>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  @doc """
  QA over whatever page is open: a chart of attempts, each story's latest
  attempt worst first, or one picked from it with the way back.
  """
  attr :latest, :list, required: true
  attr :attempts, :list, required: true, doc: "every attempt, for the chart"
  attr :picked, :map, default: nil
  attr :project_id, :string, required: true
  attr :on_pick, :string, required: true
  attr :on_back, :string, required: true
  attr :on_close, :string, required: true

  def modal(assigns) do
    ~H"""
    <div
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      data-test="qa-modal"
      phx-window-keydown={@on_close}
      phx-key="Escape"
    >
      <div class="modal-box w-11/12 max-w-3xl space-y-3">
        <button
          type="button"
          phx-click={@on_close}
          class="btn btn-ghost btn-sm btn-circle absolute right-2 top-2"
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>

        <div :if={is_nil(@picked)} class="space-y-2">
          <div class="flex items-baseline gap-2 pr-8">
            <h2 class="text-lg font-semibold">QA</h2>
            <span class="text-xs opacity-60">each story's latest attempt · worst first</span>
          </div>
          <.attempts_chart :if={@attempts != []} attempts={@attempts} compact height={120} />
          <p :if={@latest == []} class="py-6 text-center text-sm opacity-60">No QA attempts yet.</p>
          <div class="max-h-[55dvh] divide-y divide-base-200 overflow-y-auto">
            <.attempt_row :for={attempt <- @latest} attempt={attempt} on_pick={@on_pick} />
          </div>
          <div class="flex justify-end">
            <.link
              navigate={~p"/app/projects/#{@project_id}/qa"}
              data-test="qa-modal-all"
              class="btn btn-sm btn-ghost"
            >
              All QA attempts <.icon name="hero-arrow-top-right-on-square" class="size-4" />
            </.link>
          </div>
        </div>

        <div :if={@picked} class="space-y-3">
          <button
            type="button"
            phx-click={@on_back}
            data-test="qa-modal-back"
            class="btn btn-ghost btn-xs"
          >
            <.icon name="hero-arrow-left" class="size-3" /> QA
          </button>
          <div class="max-h-[60dvh] overflow-y-auto">
            <.attempt_detail attempt={@picked} project_id={@project_id} />
          </div>
        </div>
      </div>
      <button type="button" class="modal-backdrop" phx-click={@on_close} aria-label="Close"></button>
    </div>
    """
  end

  # Each day's counts by outcome: every attempt submitted that day, or every
  # story by its latest attempt up to the end of that day.
  defp day_counts("stories", attempts, days) do
    by_story = attempts |> Enum.group_by(& &1.story_id) |> Map.values()

    Enum.map(days, fn day ->
      ends = DateTime.new!(Date.add(day, 1), ~T[00:00:00], "Etc/UTC")

      by_story
      |> Enum.flat_map(&latest_before(&1, ends))
      |> Enum.frequencies_by(& &1.status)
    end)
  end

  defp day_counts(_attempts, attempts, days) do
    by_day = Enum.group_by(attempts, &DateTime.to_date(at(&1)))
    Enum.map(days, &(by_day |> Map.get(&1, []) |> Enum.frequencies_by(fn a -> a.status end)))
  end

  # A story's latest attempt before `ends`, as a list of zero or one.
  defp latest_before(tries, ends) do
    tries
    |> Enum.filter(&(DateTime.compare(at(&1), ends) == :lt))
    |> Enum.max_by(&at/1, DateTime, fn -> nil end)
    |> List.wrap()
  end

  defp days(attempts, range, today) do
    first =
      case range do
        "7d" -> Date.add(today, -6)
        "30d" -> Date.add(today, -29)
        "90d" -> Date.add(today, -89)
        _all -> attempts |> Enum.map(&DateTime.to_date(at(&1))) |> Enum.min(Date, fn -> today end)
      end

    Enum.to_list(Date.range(first, today))
  end

  defp at(attempt), do: attempt.submitted_at || attempt.inserted_at

  defp day(%DateTime{} = at), do: Calendar.strftime(at, "%b %-d, %Y")
  defp day(_at), do: "—"

  defp story_title(%{story: %{title: title}}) when is_binary(title), do: title
  defp story_title(_attempt), do: "Unknown story"

  defp story_number(%{story: %{number: number}}) when not is_nil(number), do: number
  defp story_number(_attempt), do: nil

  # Stored as JSON, so string-keyed from the database and atom-keyed in memory.
  defp scenario_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, atom_key(key))

  defp scenario_value(_other, _key), do: nil

  defp atom_key("name"), do: :name
  defp atom_key("status"), do: :status
  defp atom_key("observation"), do: :observation

  defp scenario_status(scenario) do
    case scenario_value(scenario, "status") do
      status when status in ["pass", "partial", "fail"] -> String.to_existing_atom(status)
      status when is_atom(status) and not is_nil(status) -> status
      _ -> :unknown
    end
  end

  defp status_class(:pass), do: "badge-success"
  defp status_class(:partial), do: "badge-warning"
  defp status_class(:fail), do: "badge-error"
  defp status_class(_other), do: "badge-ghost"
end
