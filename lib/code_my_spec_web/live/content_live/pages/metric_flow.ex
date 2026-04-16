defmodule CodeMySpecWeb.ContentLive.Pages.MetricFlow do
  use CodeMySpecWeb, :live_view

  import Ecto.Query

  alias CodeMySpecWeb.Layouts
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Projects.Project

  # Load copy data at compile time
  @external_resource copy_path =
                       Path.join(__DIR__, "metric_flow_case_study_copy.exs")

  @copy (case Code.eval_file(copy_path) do
           {copy, _} -> copy
         end)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.marketing flash={@flash} current_scope={@current_scope}>
      {hero_section(assigns)}
      {overview_section(assigns)}
      {stories_section(assigns)}
      {repository_section(assigns)}
      {dev_story_section(assigns)}
      {conclusion_section(assigns)}

      <.stories_modal :if={@show_stories_modal} stories={@stories} />
    </Layouts.marketing>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    stories = load_metric_flow_stories()
    base_url = CodeMySpecWeb.Endpoint.url()

    json_ld =
      Jason.encode!([
        %{
          "@context" => "https://schema.org",
          "@type" => "Article",
          "@id" => "#{base_url}/case-studies/metric-flow",
          "headline" => @copy.metadata.meta_title,
          "description" => @copy.metadata.meta_description,
          "url" => "#{base_url}/case-studies/metric-flow",
          "image" => %{
            "@type" => "ImageObject",
            "url" => "#{base_url}/images/og-metricflow.png",
            "width" => 1200,
            "height" => 630
          },
          "datePublished" => "2026-03-20T00:00:00Z",
          "dateModified" => "2026-04-04T00:00:00Z",
          "author" => %{
            "@type" => "Person",
            "@id" => "#{base_url}/author/john-davenport",
            "name" => "John Davenport",
            "url" => "#{base_url}/author/john-davenport"
          },
          "publisher" => %{
            "@type" => "Organization",
            "@id" => "#{base_url}/#organization",
            "name" => "CodeMySpec",
            "logo" => %{
              "@type" => "ImageObject",
              "url" => "#{base_url}/images/logo-300.png",
              "width" => 300,
              "height" => 300
            }
          },
          "mainEntityOfPage" => %{
            "@type" => "WebPage",
            "@id" => "#{base_url}/case-studies/metric-flow"
          },
          "articleSection" => "Case Studies"
        },
        %{
          "@context" => "https://schema.org",
          "@type" => "BreadcrumbList",
          "itemListElement" => [
            %{"@type" => "ListItem", "position" => 1, "name" => "Home", "item" => base_url},
            %{"@type" => "ListItem", "position" => 2, "name" => "Case Studies", "item" => "#{base_url}/case-studies"},
            %{"@type" => "ListItem", "position" => 3, "name" => "MetricFlow", "item" => "#{base_url}/case-studies/metric-flow"}
          ]
        }
      ])

    {:ok,
     socket
     |> assign(:copy, @copy)
     |> assign(@copy.metadata)
     |> assign(:stories, stories)
     |> assign(:show_stories_modal, false)
     |> assign(:active_tab, "good")
     |> assign(:canonical_url, "#{base_url}/case-studies/metric-flow")
     |> assign(:og_image, "#{base_url}/images/og-metricflow.png")
     |> assign(:og_type, "article")
     |> assign(:article_published_time, "2026-03-20T00:00:00Z")
     |> assign(:json_ld, json_ld)}
  end

  @impl true
  def handle_event("open_stories", _params, socket) do
    {:noreply, assign(socket, :show_stories_modal, true)}
  end

  def handle_event("close_stories", _params, socket) do
    {:noreply, assign(socket, :show_stories_modal, false)}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  # --- Data Loading ---

  defp load_metric_flow_stories do
    query =
      from s in Story,
        join: p in Project,
        on: s.project_id == p.id,
        where: ilike(p.name, "metric flow") or ilike(p.name, "metricflow"),
        order_by: [asc: s.priority, asc: s.title],
        preload: [:criteria, :tags]

    Repo.all(query)
  end

  # --- Hero Section ---

  defp hero_section(assigns) do
    ~H"""
    <div class="hero mb-16">
      <div class="hero-content text-center">
        <div class="max-w-4xl">
          <div class="badge badge-primary badge-lg mb-4">Case Study</div>
          <h1 class="text-5xl md:text-6xl font-extrabold mb-4 bg-gradient-to-r from-primary to-secondary bg-clip-text text-transparent">
            {@copy.hero.title}
          </h1>
          <p class="text-2xl md:text-3xl font-bold mb-4 text-base-content">
            {@copy.hero.tagline}
          </p>
          <p class="text-xl mb-10 text-base-content/70 max-w-2xl mx-auto">
            {@copy.hero.description}
          </p>

          <div class="stats stats-horizontal bg-base-100 shadow border border-base-300">
            <%= for stat <- @copy.hero.stats do %>
              <div class="stat px-8 py-4">
                <div class="stat-value text-primary text-2xl">{stat.value}</div>
                <div class="stat-desc text-base-content/60 text-sm">{stat.label}</div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Overview Section ---

  defp overview_section(assigns) do
    ~H"""
    <div class="mb-16" id="overview">
      <div class="text-center mb-10">
        <h2 class="text-4xl font-bold mb-4">{@copy.overview.title}</h2>
        <p class="text-xl text-base-content/70 max-w-3xl mx-auto">
          {@copy.overview.description}
        </p>
      </div>

      <div class="flex flex-wrap justify-center gap-6 mb-10">
        <%= for integration <- @copy.overview.integrations do %>
          <div class="card bg-base-100 shadow-lg border border-base-300 hover:shadow-xl transition-shadow w-48">
            <div class="card-body items-center text-center p-5">
              <.icon name={integration.icon} class="w-10 h-10 text-primary mb-2" />
              <h3 class="font-bold text-sm">{integration.name}</h3>
              <p class="text-xs text-base-content/60">{integration.description}</p>
            </div>
          </div>
        <% end %>
      </div>

      <div class="card bg-base-100 shadow-lg border border-base-300 max-w-3xl mx-auto">
        <div class="card-body">
          <h3 class="card-title text-lg mb-3">
            <.icon name="hero-list-bullet" class="w-5 h-5 text-primary" /> Key Features
          </h3>
          <ul class="space-y-2">
            <%= for feature <- @copy.overview.key_features do %>
              <li class="flex items-start gap-3">
                <.icon
                  name="hero-check-circle-solid"
                  class="w-5 h-5 text-success flex-shrink-0 mt-0.5"
                />
                <span class="text-base-content/80">{feature}</span>
              </li>
            <% end %>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  # --- Stories Section ---

  defp stories_section(assigns) do
    total_criteria = Enum.reduce(assigns.stories, 0, fn s, acc -> acc + length(s.criteria) end)
    assigns = assign(assigns, :total_criteria, total_criteria)

    ~H"""
    <div class="mb-16" id="stories">
      <div class="card bg-base-100 shadow-xl border border-base-300 max-w-3xl mx-auto">
        <div class="card-body p-8 text-center">
          <h2 class="text-3xl font-bold mb-4">
            <.icon name="hero-clipboard-document-list" class="w-8 h-8 text-primary inline" />
            User Stories
          </h2>
          <p class="text-base-content/70 mb-6">
            The stories that drove MetricFlow's development, from user registration through correlation analysis and AI chat. Every feature started as a story with testable acceptance criteria.
          </p>

          <div class="stats bg-base-200 shadow mb-6">
            <div class="stat">
              <div class="stat-value text-primary">{length(@stories)}</div>
              <div class="stat-desc">Stories</div>
            </div>
            <div class="stat">
              <div class="stat-value text-secondary">{@total_criteria}</div>
              <div class="stat-desc">Acceptance Criteria</div>
            </div>
          </div>

          <button class="btn btn-primary btn-lg gap-2" phx-click="open_stories">
            <.icon name="hero-book-open" class="w-5 h-5" /> Browse All Stories
          </button>
        </div>
      </div>
    </div>
    """
  end

  # --- Repository Section ---

  defp repository_section(assigns) do
    ~H"""
    <div class="mb-16" id="repository">
      <div class="card bg-gradient-to-br from-base-200 to-base-100 shadow-xl border border-base-300">
        <div class="card-body p-8 lg:p-10">
          <div class="flex flex-col lg:flex-row items-center gap-8">
            <div class="flex-1">
              <h2 class="text-3xl font-bold mb-3 flex items-center gap-3">
                <.icon name="hero-code-bracket" class="w-8 h-8 text-primary" />
                {@copy.repository.title}
              </h2>
              <p class="text-lg text-base-content/70 mb-6">{@copy.repository.description}</p>
              <a
                href={@copy.repository.url}
                target="_blank"
                rel="noopener noreferrer"
                class="btn btn-primary gap-2"
              >
                <.icon name="hero-arrow-top-right-on-square" class="w-5 h-5" /> View on GitHub
              </a>
            </div>
            <div class="grid grid-cols-2 gap-4">
              <%= for stat <- @copy.repository.stats do %>
                <div class="bg-base-100 rounded-box px-6 py-3 text-center border border-base-300">
                  <div class="text-sm font-bold text-primary">{stat.value}</div>
                  <div class="text-xs text-base-content/50">{stat.label}</div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Dev Story Section ---

  defp dev_story_section(assigns) do
    ~H"""
    <div class="mb-16" id="dev-story">
      <div class="text-center mb-10">
        <h2 class="text-4xl font-bold mb-2">{@copy.dev_story.title}</h2>
        <p class="text-2xl font-semibold text-base-content/80 mb-4">{@copy.dev_story.subtitle}</p>
        <p class="text-lg text-base-content/60 max-w-3xl mx-auto">
          {@copy.dev_story.description}
        </p>
      </div>

      <div class="max-w-4xl mx-auto">
        <div role="tablist" class="tabs tabs-boxed bg-base-200 mb-6 p-1">
          <button
            role="tab"
            class={"tab gap-2 #{if @active_tab == "good", do: "tab-active", else: ""}"}
            phx-click="switch_tab"
            phx-value-tab="good"
          >
            <.icon name="hero-check-circle" class="w-4 h-4" /> The Good
          </button>
          <button
            role="tab"
            class={"tab gap-2 #{if @active_tab == "bad", do: "tab-active", else: ""}"}
            phx-click="switch_tab"
            phx-value-tab="bad"
          >
            <.icon name="hero-exclamation-triangle" class="w-4 h-4" /> The Bad
          </button>
          <button
            role="tab"
            class={"tab gap-2 #{if @active_tab == "ugly", do: "tab-active", else: ""}"}
            phx-click="switch_tab"
            phx-value-tab="ugly"
          >
            <.icon name="hero-fire" class="w-4 h-4" /> The Ugly
          </button>
        </div>

        <%= for section <- @copy.dev_story.sections do %>
          <div class={if @active_tab == section.id, do: "", else: "hidden"}>
            <div class="space-y-4">
              <%= for item <- section.items do %>
                <div class={dev_story_card_class(section.id)}>
                  <div class="card-body">
                    <h3 class={"card-title text-lg #{dev_story_title_class(section.id)}"}>
                      <.icon name={section.icon} class="w-5 h-5" />
                      {item.title}
                    </h3>
                    <p class="text-base-content/70">{item.description}</p>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # --- Conclusion Section ---

  defp conclusion_section(assigns) do
    ~H"""
    <div class="mb-16" id="conclusion">
      <div class="text-center mb-10">
        <h2 class="text-4xl font-bold mb-4">{@copy.conclusion.title}</h2>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-6 max-w-4xl mx-auto mb-10">
        <%= for takeaway <- @copy.conclusion.takeaways do %>
          <div class="card bg-base-100 shadow-lg border border-base-300">
            <div class="card-body">
              <h3 class="card-title text-lg">
                <.icon name="hero-light-bulb" class="w-5 h-5 text-warning" />
                {takeaway.title}
              </h3>
              <p class="text-base-content/70 text-sm">{takeaway.description}</p>
            </div>
          </div>
        <% end %>
      </div>

      <div class="card bg-gradient-to-r from-primary/10 to-secondary/10 border border-primary/20 shadow-xl max-w-3xl mx-auto">
        <div class="card-body text-center">
          <p class="text-lg text-base-content/80">{@copy.conclusion.closing}</p>
          <div class="card-actions justify-center mt-4">
            <a href="/methodology" class="btn btn-primary gap-2">
              <.icon name="hero-book-open" class="w-5 h-5" /> Read the Full Methodology
            </a>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp dev_story_card_class("good"), do: "card bg-success/5 border border-success/20 shadow"
  defp dev_story_card_class("bad"), do: "card bg-warning/5 border border-warning/20 shadow"
  defp dev_story_card_class("ugly"), do: "card bg-error/5 border border-error/20 shadow"

  defp dev_story_title_class("good"), do: "text-success"
  defp dev_story_title_class("bad"), do: "text-warning"
  defp dev_story_title_class("ugly"), do: "text-error"

  # --- Components ---

  defp story_status_badge(%{status: :completed} = assigns) do
    ~H"""
    <div class="badge badge-success badge-sm gap-1">
      <.icon name="hero-check" class="w-3 h-3" /> Done
    </div>
    """
  end

  defp story_status_badge(%{status: :in_progress} = assigns) do
    ~H"""
    <div class="badge badge-info badge-sm gap-1">
      <.icon name="hero-arrow-path" class="w-3 h-3" /> In Progress
    </div>
    """
  end

  defp story_status_badge(%{status: :dirty} = assigns) do
    ~H"""
    <div class="badge badge-warning badge-sm gap-1">
      <.icon name="hero-exclamation-triangle" class="w-3 h-3" /> Dirty
    </div>
    """
  end

  defp story_status_badge(assigns) do
    ~H"""
    <div class="badge badge-ghost badge-sm">New</div>
    """
  end

  attr :stories, :list, required: true

  defp stories_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-4xl max-h-[85vh]">
        <div class="flex items-center justify-between mb-6 sticky top-0 bg-base-100 pb-4 z-10 border-b border-base-300">
          <h3 class="font-bold text-2xl">
            <.icon name="hero-clipboard-document-list" class="w-6 h-6 text-primary inline" />
            MetricFlow Stories ({length(@stories)})
          </h3>
          <button class="btn btn-sm btn-circle btn-ghost" phx-click="close_stories">
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>

        <div class="space-y-3 overflow-y-auto">
          <%= for story <- @stories do %>
            <div class="collapse collapse-arrow bg-base-200 border border-base-300">
              <input type="checkbox" />
              <div class="collapse-title">
                <div class="flex items-center justify-between pr-4">
                  <div class="flex-1">
                    <span class="font-semibold text-base">{story.title}</span>
                  </div>
                  <div class="flex items-center gap-2 ml-4 flex-shrink-0">
                    <.story_status_badge status={story.status} />
                    <div class="badge badge-outline badge-sm gap-1">
                      <.icon name="hero-clipboard-document-check" class="w-3 h-3" />
                      {length(story.criteria)}
                    </div>
                  </div>
                </div>
              </div>
              <div class="collapse-content">
                <p class="text-base-content/80 mb-4 leading-relaxed">
                  {story.description}
                </p>

                <div :if={story.tags != []} class="mb-4 flex flex-wrap gap-1">
                  <span :for={tag <- story.tags} class="badge badge-sm badge-outline">
                    {tag.name}
                  </span>
                </div>

                <%= if story.criteria != [] do %>
                  <h4 class="font-semibold mb-2 text-sm">Acceptance Criteria:</h4>
                  <ul class="space-y-1.5 text-base-content/80">
                    <%= for criterion <- story.criteria do %>
                      <li class="flex items-center gap-2 text-sm">
                        <.icon
                          :if={criterion.verified}
                          name="hero-lock-closed"
                          class="size-3 text-success inline flex-shrink-0"
                        />
                        <.icon
                          :if={!criterion.verified}
                          name="hero-minus-circle"
                          class="size-3 text-base-content/30 inline flex-shrink-0"
                        />
                        <span class={[criterion.verified && "font-medium"]}>
                          {criterion.description}
                        </span>
                      </li>
                    <% end %>
                  </ul>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_stories"></div>
    </div>
    """
  end
end
