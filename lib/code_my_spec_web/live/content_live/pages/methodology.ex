defmodule CodeMySpecWeb.ContentLive.Pages.Methodology do
  use CodeMySpecWeb, :live_view

  alias CodeMySpecWeb.Layouts

  # Load copy data at compile time
  @external_resource copy_path =
                       Path.join(__DIR__, "methodology_copy.exs")

  @copy (case Code.eval_file(copy_path) do
           {copy, _} -> copy
         end)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.marketing flash={@flash} current_scope={@current_scope}>
      <div id="methodology-page" phx-hook=".DeepContentRead">
        {hero_section(assigns)}
        {interactive_diagram(assigns)}
        {problem_section(assigns)}
        {solution_section(assigns)}
        {phases_detail_section(assigns)}
        {proof_section(assigns)}
        {getting_started_section(assigns)}
        {faq_section(assigns)}
        {related_content_section(assigns)}
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".DeepContentRead">
        export default {
          mounted() {
            this._timer = setTimeout(() => {
              if (typeof gtag === "function") {
                gtag("event", "deep_content_read", {
                  content_category: document.title,
                  page_path: window.location.pathname
                });
              }
            }, 60000);
          },
          destroyed() {
            clearTimeout(this._timer);
          }
        }
      </script>
    </Layouts.marketing>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:copy, @copy)
     |> assign(@copy.metadata)}
  end

  # Hero Section
  defp hero_section(assigns) do
    ~H"""
    <div class="hero mb-20">
      <div class="hero-content text-center">
        <div class="max-w-4xl">
          <h1 class="text-5xl md:text-6xl font-extrabold mb-6 bg-gradient-to-r from-primary to-secondary bg-clip-text text-transparent">
            {@copy.hero.title}
          </h1>
          <p class="text-2xl md:text-3xl font-bold mb-6 text-base-content">
            {@copy.hero.tagline}
          </p>
          <p class="text-xl mb-8 text-base-content/70 max-w-2xl mx-auto">
            {@copy.hero.description}
          </p>

          <div class="flex flex-col sm:flex-row gap-4 justify-center">
            <a href="/content/managing_user_stories" class="btn btn-primary btn-lg gap-2">
              <.icon name="hero-book-open" class="w-5 h-5" /> Start with Manual Process
            </a>
            <a href="/users/register" class="btn btn-secondary btn-lg gap-2">
              <.icon name="hero-rocket-launch" class="w-5 h-5" /> See the Automation
            </a>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Interactive Diagram Section
  defp interactive_diagram(assigns) do
    ~H"""
    <div class="mb-20" id="methodology-diagram">
      <div class="flex flex-col items-center gap-6">
        <%= for phase <- @copy.phases do %>
          <div class="card bg-base-100 shadow-xl border border-base-300 w-full max-w-md hover:shadow-2xl transition-all">
            <div class="card-body items-center text-center">
              <div class="badge badge-primary badge-lg">Phase {phase.number}</div>
              <h3 class="card-title text-2xl">{phase.icon} {phase.title}</h3>
              <p class="text-base-content/70">{phase.tagline}</p>
            </div>
          </div>
          <%= if phase.number < length(@copy.phases) do %>
            <div class="text-3xl text-primary">↓</div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # Problem Section
  defp problem_section(assigns) do
    ~H"""
    <div class="mb-20">
      <div class="text-center mb-12">
        <h2 class="text-4xl font-bold mb-4">{@copy.problem.title}</h2>
        <p class="text-xl text-base-content/70 max-w-3xl mx-auto">{@copy.problem.description}</p>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
        <%= for point <- @copy.problem.points do %>
          <div class="card bg-error/10 border border-error/20 shadow-lg">
            <div class="card-body">
              <h3 class="card-title text-error">
                <.icon name="hero-exclamation-triangle" class="w-6 h-6" />
                {point.title}
              </h3>
              <p class="text-base-content/70">{point.description}</p>
            </div>
          </div>
        <% end %>
      </div>

      <div class="alert alert-warning shadow-lg max-w-3xl mx-auto">
        <.icon name="hero-exclamation-triangle" class="w-6 h-6" />
        <span class="font-semibold">{@copy.problem.conclusion}</span>
      </div>
    </div>
    """
  end

  # Solution Section
  defp solution_section(assigns) do
    ~H"""
    <div class="mb-20">
      <div class="card bg-gradient-to-br from-success/20 to-primary/20 shadow-2xl border border-success/20">
        <div class="card-body p-8 lg:p-12">
          <h2 class="card-title text-3xl mb-6 gap-3">
            <.icon name="hero-light-bulb" class="w-8 h-8 text-success" />
            {@copy.solution.title}
          </h2>
          <p class="text-xl text-base-content/80 mb-6">{@copy.solution.description}</p>

          <div class="space-y-4 mb-6">
            <%= for item <- @copy.solution.approach do %>
              <div class="flex gap-3 items-start">
                <.icon name="hero-check-circle-solid" class="w-6 h-6 text-success flex-shrink-0 mt-1" />
                <p class="text-lg">{item}</p>
              </div>
            <% end %>
          </div>

          <div class="alert alert-success shadow-lg">
            <.icon name="hero-sparkles" class="w-6 h-6" />
            <span class="text-lg font-bold">{@copy.solution.tagline}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Phases Detail Section
  defp phases_detail_section(assigns) do
    ~H"""
    <div class="mb-20">
      <div class="text-center mb-12">
        <h2 class="text-4xl font-bold">The Six Phases</h2>
      </div>

      <div class="space-y-8">
        <%= for phase <- @copy.phases do %>
          <div class="card bg-base-100 shadow-xl border border-base-300" id={"phase-#{phase.number}"}>
            <div class="card-body">
              <div class="flex items-center gap-3 mb-4">
                <div class="badge badge-primary badge-lg">Phase {phase.number}</div>
                <h3 class="card-title text-2xl">{phase.icon} {phase.title}</h3>
              </div>
              <p class="text-lg text-base-content/70 mb-4">{phase.tagline}</p>

              <div class="divider"></div>

              <div class="mb-4">
                <h4 class="font-bold text-lg mb-2">What You Create</h4>
                <div class="text-base-content/70">{raw(phase.creates)}</div>
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mb-4">
                <div class="card bg-base-200 border border-base-300">
                  <div class="card-body">
                    <h4 class="card-title text-base">
                      <.icon name="hero-hand-raised" class="w-5 h-5" /> Manual
                    </h4>
                    <p class="text-sm mb-3">{phase.manual.description}</p>
                    <ul class="list-disc list-inside text-sm space-y-1 text-base-content/70">
                      <%= for step <- phase.manual.steps do %>
                        <li>{step}</li>
                      <% end %>
                    </ul>
                    <div class="mt-3">
                      <.render_guide_link guide={phase.manual.guide} />
                    </div>
                  </div>
                </div>

                <div class="card bg-primary/5 border border-primary/20">
                  <div class="card-body">
                    <h4 class="card-title text-base">
                      <.icon name="hero-bolt" class="w-5 h-5 text-primary" /> Automated
                    </h4>
                    <p class="text-sm mb-3">{phase.automated.description}</p>
                    <%= if Map.has_key?(phase.automated, :steps) do %>
                      <ul class="list-disc list-inside text-sm space-y-1 text-base-content/70">
                        <%= for step <- phase.automated.steps do %>
                          <li>{step}</li>
                        <% end %>
                      </ul>
                    <% end %>
                    <div class="mt-3">
                      <.render_guide_link guide={phase.automated.guide} />
                    </div>
                  </div>
                </div>
              </div>

              <div class="alert alert-info">
                <.icon name="hero-code-bracket" class="w-5 h-5" />
                <div>
                  <div class="font-bold">Example from CodeMySpec</div>
                  <div class="text-sm">
                    <strong>{phase.example.title}:</strong>
                    {phase.example.description}
                    <code class="text-xs bg-base-300 px-2 py-1 rounded ml-2">
                      {phase.example.file}
                    </code>
                  </div>
                </div>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Proof Section
  defp proof_section(assigns) do
    ~H"""
    <div class="mb-20">
      <div class="card bg-base-100 shadow-2xl border border-base-300">
        <div class="card-body p-8 lg:p-12">
          <h2 class="card-title text-3xl mb-4 gap-3">
            <.icon name="hero-shield-check" class="w-8 h-8 text-success" />
            {@copy.proof.title}
          </h2>
          <p class="text-xl text-base-content/70 mb-6">{@copy.proof.description}</p>

          <ul class="space-y-3 mb-6">
            <%= for item <- @copy.proof.evidence do %>
              <li class="flex gap-3 items-start">
                <.icon name="hero-check-circle-solid" class="w-6 h-6 text-success flex-shrink-0 mt-1" />
                <span class="text-lg">{item}</span>
              </li>
            <% end %>
          </ul>

          <div class="alert alert-info shadow-lg">
            <.icon name="hero-link" class="w-6 h-6" />
            <span class="font-bold">{@copy.proof.tagline}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Getting Started Section
  defp getting_started_section(assigns) do
    ~H"""
    <div class="mb-20">
      <div class="text-center mb-12">
        <h2 class="text-4xl font-bold">{@copy.getting_started.title}</h2>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
        <%= for path <- @copy.getting_started.paths do %>
          <div class="card bg-base-100 shadow-xl border border-base-300 hover:shadow-2xl transition-all">
            <div class="card-body">
              <h3 class="card-title text-2xl">{path.name}</h3>
              <p class="text-base-content/70">{path.description}</p>
              <div class="badge badge-outline">{path.time}</div>

              <div class="divider"></div>

              <div class="mb-4">
                <h4 class="font-bold mb-2">Best for:</h4>
                <ul class="list-disc list-inside space-y-1 text-sm text-base-content/70">
                  <%= for item <- path.best_for do %>
                    <li>{item}</li>
                  <% end %>
                </ul>
              </div>

              <div class="mb-4">
                <h4 class="font-bold mb-2">Steps:</h4>
                <ol class="list-decimal list-inside space-y-1 text-sm text-base-content/70">
                  <%= for step <- path.steps do %>
                    <li>{step}</li>
                  <% end %>
                </ol>
              </div>

              <div class="card-actions justify-end mt-4">
                <a href={path.cta.url} class="btn btn-primary gap-2">
                  <.icon name="hero-arrow-right" class="w-5 h-5" />
                  {path.cta.text}
                </a>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # FAQ Section
  defp faq_section(assigns) do
    ~H"""
    <div class="mb-20">
      <div class="text-center mb-12">
        <h2 class="text-4xl font-bold">FAQ</h2>
      </div>

      <div class="space-y-4 max-w-4xl mx-auto">
        <%= for item <- @copy.faq do %>
          <div class="collapse collapse-plus bg-base-100 border border-base-300">
            <input type="checkbox" />
            <div class="collapse-title text-xl font-medium">
              {item.question}
            </div>
            <div class="collapse-content">
              <p class="text-base-content/70">{item.answer}</p>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Related Content Section
  defp related_content_section(assigns) do
    ~H"""
    <div class="mb-20">
      <div class="text-center mb-12">
        <h2 class="text-4xl font-bold">Related Content</h2>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-8 max-w-4xl mx-auto">
        <div class="card bg-base-100 shadow-xl border border-base-300">
          <div class="card-body">
            <h3 class="card-title">
              <.icon name="hero-map" class="w-6 h-6 text-primary" /> Main Quest
            </h3>
            <ul class="menu menu-compact">
              <%= for item <- @copy.related_content.main_quest do %>
                <.render_content_link item={item} />
              <% end %>
            </ul>
          </div>
        </div>

        <div class="card bg-base-100 shadow-xl border border-base-300">
          <div class="card-body">
            <h3 class="card-title">
              <.icon name="hero-sparkles" class="w-6 h-6 text-secondary" /> Side Quest
            </h3>
            <ul class="menu menu-compact">
              <%= for item <- @copy.related_content.side_quest do %>
                <.render_content_link item={item} />
              <% end %>
            </ul>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions
  attr :guide, :map, required: true

  defp render_guide_link(%{guide: %{status: :published}} = assigns) do
    ~H"""
    <a href={@guide.url} class="btn btn-sm btn-link gap-2">
      {@guide.title}
      <.icon name="hero-arrow-right" class="w-4 h-4" />
    </a>
    """
  end

  defp render_guide_link(%{guide: %{status: status}} = assigns)
       when status in [:draft, :planned] do
    ~H"""
    <div class="badge badge-outline gap-2">
      <.icon name="hero-clock" class="w-3 h-3" />
      {@guide.title} (Coming Soon)
    </div>
    """
  end

  attr :item, :map, required: true

  defp render_content_link(%{item: %{status: :published}} = assigns) do
    ~H"""
    <li>
      <a href={@item.url} class="flex items-center gap-2">
        <.icon name="hero-document-text" class="w-4 h-4" />
        {@item.title}
      </a>
    </li>
    """
  end

  defp render_content_link(%{item: %{status: status}} = assigns)
       when status in [:draft, :planned] do
    ~H"""
    <li class="opacity-60">
      <span class="flex items-center gap-2">
        <.icon name="hero-clock" class="w-4 h-4" />
        {@item.title} (Coming Soon)
      </span>
    </li>
    """
  end
end
