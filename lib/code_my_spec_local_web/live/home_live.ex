defmodule CodeMySpecLocalWeb.HomeLive do
  @moduledoc """
  Project overview / dashboard — landing page for a single project.

  When the project has zero stories the page renders the per-project
  onboarding ladder (story 701) — three rungs (init, project setup,
  first story) using the same chamfered shell + "// step 0N · <name>"
  eyebrow as the dashboard's ladder. Once the project has at least
  one story the page falls back to the standard dash-card grid.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Analysis
  alias CodeMySpec.Events
  alias CodeMySpec.Problems
  alias CodeMySpec.Projects
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils

  # Operate/grow CTA destinations (the hosted connect + operate conversion
  # surface) don't exist yet. v1 points the "connect" and "start operating"
  # CTAs at the done-with-you booking so the funnel is real today with no new
  # backend. TODO(john): replace with your real booking link, then swap the
  # CTA hrefs for the real /connect + /operate routes when they ship.
  @book_call_url "https://cal.com/john-s10-davenport"

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()
    {:ok, assign(socket, projects: projects, project: nil, scope: nil, error: nil)}
  end

  @impl true
  def handle_params(%{"project_id" => id}, _uri, socket) do
    case load_project_and_scope(id) do
      {:ok, project, scope} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "analysis:#{project.id}")
        end

        {:noreply,
         socket
         |> assign(
           project: project,
           scope: scope,
           slug: project.id,
           dir_param: URI.encode_www_form(scope.cwd),
           page_title: project.name,
           error: nil
         )
         |> assign_ladder_state(project, scope)
         |> assign_analysis_gauge(scope)}

      {:error, msg} ->
        {:noreply, assign(socket, error: "#{msg}")}
    end
  end

  # Run-service transitions push here; reload the gauge from the ledger.
  @impl true
  def handle_info({:analysis, _event}, socket) do
    {:noreply, assign_analysis_gauge(socket, socket.assigns.scope)}
  end

  # Fixed display order; `Analysis.status/1` covers every source.
  @gauge_sources [
    {"compiler", "compile"},
    {"credo", "credo"},
    {"exunit", "test"},
    {"spex", "spex"}
  ]

  # Gauge is decorative — a missing ledger table (mid-migration) or any read
  # hiccup must not take down the dashboard. `Utils.rescued/3` logs it instead
  # of the failure reading identical to "nothing to show."
  defp assign_analysis_gauge(socket, scope) do
    gauge =
      Utils.rescued("HomeLive.assign_analysis_gauge", [], fn ->
        status = Analysis.status(scope)

        problem_counts =
          scope
          |> Problems.list_project_problems([])
          |> Enum.frequencies_by(& &1.source)

        Enum.map(@gauge_sources, fn {source, label} ->
          %{state: state, run: run} = Map.fetch!(status, source)

          %{
            source: source,
            label: label,
            state: state,
            problems: Map.get(problem_counts, source, 0),
            finished_at: run && run.finished_at
          }
        end)
      end)

    assign(socket, :analysis_gauge, gauge)
  end

  defp assign_ladder_state(socket, project, scope) do
    init_done? = Events.exists?("local_init_complete", project_id: project.id)
    setup_done? = Events.exists?("local_project_setup_complete", project_id: project.id)
    stories_count = safe_count_stories(scope)
    has_stories? = stories_count > 0

    socket
    |> assign(:init_done?, init_done?)
    |> assign(:setup_done?, setup_done?)
    |> assign(:stories_count, stories_count)
    |> assign(:has_stories?, has_stories?)
    |> assign(:active_rung, active_rung(init_done?, setup_done?, has_stories?))
    |> assign(:operate_state, operate_state(project))
  end

  # Link state IS the funnel. A project with no account_id is "floating" —
  # local-first, offline, never connected to a server account. Once it has an
  # account_id it's linked to a (billable) server account, where operate/grow
  # lives. `:operating` (account actively paying) is a later split off :linked.
  defp operate_state(%{account_id: nil}), do: :floating
  defp operate_state(%{account_id: _}), do: :linked

  # Stories are moving from the dashboard server to the local CLI DB.
  # During the migration window the server-side stories table may be
  # absent (drop_stories_and_attached). Treat any DB-side absence as
  # "no stories" so the per-project ladder still renders correctly.
  defp safe_count_stories(scope) do
    length(Stories.list_stories(scope))
  rescue
    Postgrex.Error -> 0
    DBConnection.ConnectionError -> 0
  end

  defp active_rung(false, _, _), do: :init
  defp active_rung(true, false, _), do: :project_setup
  defp active_rung(true, true, false), do: :first_story
  defp active_rung(true, true, true), do: nil

  defp rung_state(rung, active, init_done?, setup_done?, has_stories?) do
    cond do
      rung == active -> "active"
      rung == :init and init_done? -> "done"
      rung == :project_setup and setup_done? -> "done"
      rung == :first_story and has_stories? -> "done"
      true -> "pending"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      projects={@projects}
      project={@project}
      section={:overview}
      page_title={assigns[:page_title]}
    >
      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={@project && !@error}>
        <div class="mb-8 flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1>{@project.name}</h1>
            <p :if={@project.local_path} class="text-sm opacity-60 font-mono mt-1">
              {@project.local_path}
            </p>
          </div>
          <.analysis_gauge gauge={assigns[:analysis_gauge] || []} />
        </div>

        <.per_project_ladder :if={!@has_stories?} {assigns} />

        <.dash_cards :if={@has_stories?} slug={@slug} />

        <.operate_band operate_state={@operate_state} slug={@slug} />
      </div>
    </Layouts.app>
    """
  end

  # Analyzer activity gauge — one dot per analyzer source so the engineer can
  # see at a glance what's running, what's fresh, and what found problems.
  # States: running (pulsing amber), problems (signal red + count), fresh
  # (green), failed (red ring), stale (hollow). Live via "analysis:<id>"
  # PubSub from the run service.
  defp analysis_gauge(%{gauge: []} = assigns), do: ~H""

  defp analysis_gauge(assigns) do
    ~H"""
    <div
      data-test="analysis-gauge"
      class="flex items-center gap-3 rounded-box border border-base-300 bg-base-200/60 px-3 py-1.5 font-mono text-xs"
    >
      <div
        :for={item <- @gauge}
        class="flex items-center gap-1.5"
        title={gauge_tooltip(item)}
        data-test={"gauge-#{item.source}"}
        data-state={item.state}
      >
        <span class={["inline-block size-2 rounded-full", gauge_dot(item)]}></span>
        <span class="opacity-60">{item.label}</span>
        <span :if={item.problems > 0} class="font-bold text-error">{item.problems}</span>
      </div>
    </div>
    """
  end

  defp gauge_dot(%{state: :running}), do: "bg-warning animate-pulse"
  defp gauge_dot(%{problems: count}) when count > 0, do: "bg-error"
  defp gauge_dot(%{state: :fresh}), do: "bg-success"
  defp gauge_dot(%{state: :failed}), do: "bg-transparent ring-1 ring-error"
  defp gauge_dot(_item), do: "bg-transparent ring-1 ring-base-content/30"

  defp gauge_tooltip(item) do
    finished =
      case item.finished_at do
        %DateTime{} = dt -> " · last run #{Calendar.strftime(dt, "%H:%M:%S")}"
        _ -> ""
      end

    problems = if item.problems > 0, do: " · #{item.problems} problem(s)", else: ""
    "#{item.source}: #{item.state}#{problems}#{finished}"
  end

  defp per_project_ladder(assigns) do
    assigns =
      assign(assigns, :active, assigns.active_rung)

    ~H"""
    <div data-test="per-project-ladder" class="mx-auto max-w-2xl flex flex-col gap-4">
      <.rung
        rung={:init}
        eyebrow="// step 01 · init"
        hint="Run setup commands to prepare this directory."
        slug={@slug}
        state={rung_state(:init, @active, @init_done?, @setup_done?, @has_stories?)}
      />

      <.rung
        rung={:project_setup}
        eyebrow="// step 02 · project setup"
        hint="Paste /codemyspec:next in Claude Code."
        slug={@slug}
        state={rung_state(:project_setup, @active, @init_done?, @setup_done?, @has_stories?)}
      />

      <.rung
        rung={:first_story}
        eyebrow="// step 03 · first story"
        hint="Let the agent interview you — or write the story yourself."
        slug={@slug}
        state={rung_state(:first_story, @active, @init_done?, @setup_done?, @has_stories?)}
      />
    </div>
    """
  end

  # Audit re-pass §2e: rungs previously rendered eyebrow on the left and the
  # rung label *repeated* on the right (`// step 01 · init` … `Init`). Now:
  #   - active rungs show only the eyebrow above the CTA (no doubled label)
  #   - pending rungs show a one-line preview hint instead of the label
  #   - done rungs show a `✓` indicator on the right
  defp rung(%{rung: rung} = assigns) do
    test_id = rung_test_id(rung)
    assigns = assign(assigns, :test_id, test_id)

    ~H"""
    <div
      data-test={@test_id}
      data-state={@state}
      class="cms-onboarding"
      style={if @state == "pending", do: "opacity: 0.55;", else: ""}
    >
      <div class="flex items-center gap-4 px-6 py-5">
        <span class="cms-onboarding-eyebrow">{@eyebrow}</span>
        <span class="flex-1"></span>
        <span :if={@state == "done"} class="cms-onboarding-eyebrow" style="opacity: 0.7;">
          ✓ Done
        </span>
        <span :if={@state == "pending"} class="font-mono text-xs opacity-60 hidden sm:inline">
          {@hint}
        </span>
      </div>

      <.rung_cta :if={@state == "active"} rung={@rung} slug={@slug} />
    </div>
    """
  end

  defp rung_cta(%{rung: :init} = assigns) do
    ~H"""
    <div class="px-6 pb-5 -mt-2 flex items-center gap-3 flex-wrap">
      <.link
        navigate={~p"/app/projects/#{@slug}/init"}
        class="cms-onboarding-cta"
        data-test="init-rung-cta"
      >
        <span>▸</span> Open init checklist
      </.link>
      <span class="text-xs opacity-60">
        Step prompts ready to paste into Claude Code.
      </span>
    </div>
    """
  end

  defp rung_cta(%{rung: :project_setup} = assigns) do
    ~H"""
    <div class="px-6 pb-5 -mt-2 flex items-center gap-3 flex-wrap">
      <div class="flex items-center gap-2">
        <code class="kbd kbd-sm" data-test="project-setup-rung-cmd">/codemyspec:next</code>
        <button
          type="button"
          class="copy-btn btn btn-xs btn-primary"
          data-copy="/codemyspec:next"
          data-test="project-setup-rung-copy"
          aria-label="Copy /codemyspec:next to clipboard"
        >
          Copy
        </button>
      </div>
      <span class="text-xs opacity-60">
        Paste in Claude Code — the agent runs project setup automatically.
      </span>
    </div>
    """
  end

  # Audit re-pass §2e + brief §5c: lead with the agent-interview path
  # (Matt's drop-off was the form). Form path is now the muted secondary
  # affordance for users who already know what they want to write.
  defp rung_cta(%{rung: :first_story} = assigns) do
    ~H"""
    <div class="px-6 pb-5 -mt-2 flex flex-col gap-3">
      <div class="flex items-center gap-2 flex-wrap" data-test="first-story-rung-cta">
        <code class="kbd kbd-sm">/codemyspec:product interview</code>
        <button
          type="button"
          class="copy-btn cms-onboarding-copy"
          data-copy="/codemyspec:product interview"
          aria-label="Copy /codemyspec:product interview to clipboard"
        >
          Copy
        </button>
        <span class="text-xs opacity-60 font-mono">
          Paste in Claude Code — the agent interviews you and drafts the story.
        </span>
      </div>
      <div class="flex items-center gap-3 flex-wrap text-xs font-mono opacity-70">
        <span>— or write it yourself:</span>
        <.link
          navigate={~p"/app/projects/#{@slug}/stories/new"}
          class="underline hover:opacity-100"
          data-test="first-story-rung-form-link"
        >
          Write your first story →
        </.link>
      </div>
    </div>
    """
  end

  defp rung_test_id(:init), do: "init-rung"
  defp rung_test_id(:project_setup), do: "project-setup-rung"
  defp rung_test_id(:first_story), do: "first-story-rung"

  # The build→operate bridge. Build is free; operate/grow is the paid layer on
  # the project's server account. This band is the only door from the free
  # engineer surface to the money — rendered on every project state:
  #   :floating → not connected to a server account yet → offer to connect
  #   :linked   → connected → offer to turn on operate/grow
  #   :operating → paying → live deep-links (built later, off :linked split)
  # NOTE(john): all copy below is a draft placeholder — rewrite in your voice.
  attr :operate_state, :atom, required: true
  attr :slug, :string, required: true

  defp operate_band(%{operate_state: :floating} = assigns) do
    assigns = assign(assigns, :book_call_url, @book_call_url)

    ~H"""
    <div data-test="operate-band" data-state="floating" class="cms-onboarding mt-10">
      <div class="px-6 py-6 flex flex-col gap-3">
        <span class="cms-onboarding-eyebrow">// operate &amp; grow</span>
        <h2 class="text-lg font-semibold">This project is local-only.</h2>
        <p class="text-sm opacity-70 max-w-xl">
          It's not connected to a server account yet. Connect it to a workspace to
          run it in production — custom-domain email, live chat, and the ads and
          analytics tooling. Building stays free; the hosted server is what you
          pay for.
        </p>
        <div class="flex items-center gap-3 flex-wrap">
          <a href={@book_call_url} class="cms-onboarding-cta" data-test="operate-band-connect-cta">
            <span>▸</span> Connect to a workspace
          </a>
        </div>
      </div>
    </div>
    """
  end

  defp operate_band(%{operate_state: :linked} = assigns) do
    assigns = assign(assigns, :book_call_url, @book_call_url)

    ~H"""
    <div data-test="operate-band" data-state="linked" class="cms-onboarding mt-10">
      <div class="px-6 py-6 flex flex-col gap-3">
        <span class="cms-onboarding-eyebrow">// operate &amp; grow</span>
        <h2 class="text-lg font-semibold">Connected. Ready to ship.</h2>
        <p class="text-sm opacity-70 max-w-xl">
          Operate &amp; grow runs on the hosted server — custom-domain email and
          live chat in one inbox, plus content, ads, and conversion analytics.
          Turn it on when you're ready to put this in front of users.
        </p>
        <div class="flex items-center gap-3 flex-wrap">
          <a href={@book_call_url} class="cms-onboarding-cta" data-test="operate-band-operate-cta">
            <span>▸</span> Start operating
          </a>
          <span class="text-xs opacity-60">
            or set it up with John — <a href={@book_call_url} class="underline">book a call</a>.
          </span>
        </div>
      </div>
    </div>
    """
  end

  # Audit re-pass §2i: workshop dash-cards must cover every section the
  # sidebar exposes — Personas and Scheduler were in `// data` but missing
  # from the grid. Now the two surfaces stay in sync.
  defp dash_cards(assigns) do
    ~H"""
    <div data-test="project-home-dashcards" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      <.dash_card
        title="Next Task"
        href={~p"/app/projects/#{@slug}/next-task"}
        desc="Pick up the next actionable requirement."
      />
      <.dash_card
        title="Files & Sync"
        href={~p"/app/projects/#{@slug}/files"}
        desc="Inspect tracked files and re-sync the projection."
      />
      <.dash_card
        title="Configuration"
        href={~p"/app/projects/#{@slug}/configuration"}
        desc="Quality gate and analyzer settings."
      />

      <.dash_card
        title="Requirements"
        href={~p"/app/projects/#{@slug}/requirements"}
        desc="Project-level requirement graph."
      />
      <.dash_card
        title="Stories"
        href={~p"/app/projects/#{@slug}/stories"}
        desc="User stories and acceptance criteria."
      />
      <.dash_card
        title="Scheduler"
        href={~p"/app/projects/#{@slug}/stories/scheduler"}
        desc="Order and prioritize the story backlog."
      />

      <.dash_card
        title="Personas"
        href={~p"/app/projects/#{@slug}/personas"}
        desc="User personas linked to stories."
      />
      <.dash_card
        title="Issues"
        href={~p"/app/projects/#{@slug}/issues"}
        desc="Open problems and incoming triage."
      />
      <.dash_card
        title="Sessions"
        href={~p"/app/projects/#{@slug}/sessions"}
        desc="Agent session history."
      />

      <.dash_card
        title="Project Init"
        href={~p"/app/projects/#{@slug}/init"}
        desc="Bootstrap checklist for this directory."
      />
      <.dash_card
        title="Knowledge Base"
        href={~p"/app/projects/#{@slug}/knowledge"}
        desc="Shared methodology and rules."
      />
      <.dash_card
        title="Project Knowledge"
        href={~p"/app/projects/#{@slug}/project-knowledge"}
        desc="Project-specific docs and specs."
      />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :href, :string, required: true
  attr :desc, :string, required: true

  defp dash_card(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class="card bg-base-200 border border-base-300 hover:border-primary hover:shadow-lg transition"
    >
      <div class="card-body p-5">
        <h2 class="card-title text-base">{@title}</h2>
        <p class="text-sm opacity-70">{@desc}</p>
      </div>
    </.link>
    """
  end

  defp load_project_and_scope(id) do
    with %Projects.Project{} = project <- Projects.get_project_by_id(id),
         {:ok, scope} <- Scope.for_local_project(project) do
      {:ok, project, scope}
    else
      # `get_project_by_id/1` answers nil, which fell out of the `with` as nil
      # and hit the caller's `case` with no matching clause. An unknown project
      # is an ordinary thing to ask for; it should say so.
      nil -> {:error, "Project not found."}
      {:error, reason} -> {:error, reason}
    end
  end
end
