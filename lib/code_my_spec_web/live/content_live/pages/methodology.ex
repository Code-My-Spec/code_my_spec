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
    base_url = CodeMySpecWeb.Endpoint.url()

    json_ld =
      Jason.encode!([
        %{
          "@context" => "https://schema.org",
          "@type" => "TechArticle",
          "headline" => @copy.metadata.meta_title,
          "description" => @copy.metadata.meta_description,
          "url" => "#{base_url}/methodology",
          "image" => %{
            "@type" => "ImageObject",
            "url" => "#{base_url}/images/og-methodology.png"
          },
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
              "url" => "#{base_url}/images/logo.svg"
            }
          },
          "mainEntityOfPage" => %{
            "@type" => "WebPage",
            "@id" => "#{base_url}/methodology"
          },
          "datePublished" => "2026-03-01T00:00:00Z",
          "dateModified" => "2026-04-04T00:00:00Z",
          "proficiencyLevel" => "Expert",
          "articleSection" => "Methodology"
        },
        %{
          "@context" => "https://schema.org",
          "@type" => "BreadcrumbList",
          "itemListElement" => [
            %{"@type" => "ListItem", "position" => 1, "name" => "Home", "item" => base_url},
            %{"@type" => "ListItem", "position" => 2, "name" => "Methodology"}
          ]
        },
        %{
          "@context" => "https://schema.org",
          "@type" => "FAQPage",
          "mainEntity" =>
            Enum.map(@copy.faq, fn item ->
              %{
                "@type" => "Question",
                "name" => item.question,
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" => item.answer
                }
              }
            end)
        }
      ])

    {:ok,
     socket
     |> assign(:copy, @copy)
     |> assign(@copy.metadata)
     |> assign(:canonical_url, "#{base_url}/methodology")
     |> assign(:og_image, "#{base_url}/images/og-methodology.png")
     |> assign(:og_type, "article")
     |> assign(:json_ld, json_ld)}
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
          <p class="text-xl mb-6 text-base-content/70 max-w-2xl mx-auto">
            {@copy.hero.description}
          </p>
          <p class="text-sm text-base-content/50 mb-8">
            By <a href="/author/john-davenport" class="hover:text-primary transition-colors">John Davenport</a>
          </p>

          <a href="/users/register" class="btn btn-primary btn-lg gap-2">
            <.icon name="hero-rocket-launch" class="w-5 h-5" /> Try CodeMySpec
          </a>
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
          <a
            href={"#phase-#{phase.number}"}
            class="card bg-base-100 shadow-xl border border-base-300 w-full max-w-md hover:shadow-2xl transition-all hover:-translate-y-1"
          >
            <div class="card-body items-center text-center py-4">
              <div class="flex items-center gap-3">
                <div class="badge badge-primary">Phase {phase.number}</div>
                <h3 class="font-bold text-lg">
                  <.icon name={phase.icon} class="w-5 h-5 inline" /> {phase.title}
                </h3>
              </div>
              <p class="text-sm text-base-content/70">{phase.tagline}</p>
            </div>
          </a>
          <%= if phase.number < length(@copy.phases) do %>
            <div class="text-2xl text-primary">↓</div>
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
                <.icon
                  name="hero-check-circle-solid"
                  class="w-6 h-6 text-success flex-shrink-0 mt-1"
                />
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
          <div
            class="card bg-base-100 shadow-xl border border-base-300"
            id={"phase-#{phase.number}"}
          >
            <div class="card-body">
              <div class="flex items-center gap-3 mb-2">
                <div class="badge badge-primary badge-lg">Phase {phase.number}</div>
                <h3 class="card-title text-2xl">
                  <.icon name={phase.icon} class="w-6 h-6" /> {phase.title}
                </h3>
              </div>
              <p class="text-lg text-base-content/70 mb-4">{phase.tagline}</p>

              <p class="text-base-content/80 mb-4">{phase.description}</p>

              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 mb-4">
                <%= for highlight <- phase.highlights do %>
                  <div class="flex gap-2 items-start">
                    <.icon
                      name="hero-check-circle-solid"
                      class="w-5 h-5 text-success flex-shrink-0 mt-0.5"
                    />
                    <span class="text-sm text-base-content/70">{highlight}</span>
                  </div>
                <% end %>
              </div>

              <div class="flex items-center justify-between">
                <div class="badge badge-outline gap-2">
                  <.icon name="hero-document-text" class="w-3 h-3" />
                  Creates: {phase.creates}
                </div>
                <.render_guide_link guide={phase.guide} />
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
                <.icon
                  name="hero-check-circle-solid"
                  class="w-6 h-6 text-success flex-shrink-0 mt-1"
                />
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
        <p class="text-xl text-base-content/70 max-w-2xl mx-auto mt-4">
          {@copy.getting_started.description}
        </p>
      </div>

      <div class="card bg-base-100 shadow-xl border border-base-300 max-w-3xl mx-auto">
        <div class="card-body">
          <ol class="space-y-4">
            <%= for {step, idx} <- Enum.with_index(@copy.getting_started.steps, 1) do %>
              <li class="flex gap-4 items-start">
                <div class="badge badge-primary badge-lg flex-shrink-0">{idx}</div>
                <span class="text-lg pt-0.5">{step}</span>
              </li>
            <% end %>
          </ol>

          <div class="card-actions justify-center mt-8">
            <a href={@copy.getting_started.cta.url} class="btn btn-primary btn-lg gap-2">
              <.icon name="hero-rocket-launch" class="w-5 h-5" />
              {@copy.getting_started.cta.text}
            </a>
          </div>
        </div>
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

      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4 max-w-4xl mx-auto">
        <%= for item <- @copy.related_content do %>
          <.render_content_link item={item} />
        <% end %>
      </div>
    </div>
    """
  end

  # Helper functions
  attr :guide, :map, required: true

  defp render_guide_link(%{guide: %{status: :published}} = assigns) do
    ~H"""
    <a href={@guide.url} class="btn btn-sm btn-ghost gap-2">
      {@guide.title}
      <.icon name="hero-arrow-right" class="w-4 h-4" />
    </a>
    """
  end

  defp render_guide_link(%{guide: %{status: status}} = assigns)
       when status in [:draft, :planned] do
    ~H"""
    <div class="badge badge-outline badge-sm gap-2">
      <.icon name="hero-clock" class="w-3 h-3" />
      Coming Soon
    </div>
    """
  end

  attr :item, :map, required: true

  defp render_content_link(%{item: %{status: :published}} = assigns) do
    ~H"""
    <a
      href={@item.url}
      class="card bg-base-100 border border-base-300 hover:shadow-lg transition-shadow"
    >
      <div class="card-body py-4 px-5">
        <div class="flex items-center gap-2">
          <.icon name="hero-document-text" class="w-4 h-4 text-primary flex-shrink-0" />
          <span class="font-medium text-sm">{@item.title}</span>
        </div>
      </div>
    </a>
    """
  end

  defp render_content_link(%{item: %{status: status}} = assigns)
       when status in [:draft, :planned] do
    ~H"""
    <div class="card bg-base-200 border border-base-300 opacity-60">
      <div class="card-body py-4 px-5">
        <div class="flex items-center gap-2">
          <.icon name="hero-clock" class="w-4 h-4 flex-shrink-0" />
          <span class="text-sm">{@item.title} (Coming Soon)</span>
        </div>
      </div>
    </div>
    """
  end
end
