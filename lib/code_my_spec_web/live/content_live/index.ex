defmodule CodeMySpecWeb.ContentLive.Index do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Content

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.marketing flash={@flash} current_scope={@current_scope}>
      <!-- Header -->
      <div class="text-center mb-16">
        <div class="badge badge-primary badge-lg mb-4">Blog</div>
        <h1 class="text-5xl md:text-6xl font-extrabold mb-6">
          Latest Articles
        </h1>
        <p class="text-xl text-base-content/70 max-w-2xl mx-auto">
          Insights on structured AI development, avoiding LLM-generated technical debt, and building production-ready Phoenix applications.
        </p>
      </div>
      <!-- Blog Posts Grid -->
      <div :if={@posts == []} class="text-center py-20">
        <div class="avatar placeholder mb-4">
          <div class="bg-base-300 text-base-content rounded-full w-20">
            <.icon name="hero-document-text" class="w-10 h-10" />
          </div>
        </div>
        <h2 class="text-2xl font-bold mb-2">No posts yet</h2>
        <p class="text-base-content/70">Check back soon for new content!</p>
      </div>

      <div :if={@posts != []} class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-8">
        <%= for post <- @posts do %>
          <.link navigate={~p"/blog/#{post.slug}"} class="group">
            <article class="card bg-base-100 shadow-xl hover:shadow-2xl transition-all duration-300 hover:-translate-y-2 border border-base-300 h-full">
              <div class="card-body gap-4">
                <!-- Date Badge -->
                <div class="flex items-center gap-2 text-sm text-base-content/60">
                  <.icon name="hero-calendar" class="w-4 h-4" />
                  <time datetime={post.publish_at}>
                    {format_date(post.publish_at)}
                  </time>
                </div>
                <!-- Title -->
                <h2 class="card-title text-2xl group-hover:text-primary transition-colors">
                  {post.title || post.slug}
                </h2>
                <!-- Excerpt -->
                <p class="text-base-content/70 line-clamp-3">
                  {extract_excerpt(post)}
                </p>
                <!-- Tags -->
                <div :if={post.tags && post.tags != []} class="flex gap-2 flex-wrap mt-auto">
                  <span
                    :for={tag <- Enum.take(post.tags, 3)}
                    class="badge badge-sm badge-outline"
                  >
                    {tag.name}
                  </span>
                </div>
                <!-- Read More -->
                <div class="card-actions justify-end mt-4">
                  <div class="btn btn-sm btn-ghost gap-2 group-hover:gap-3 transition-all">
                    Read More <.icon name="hero-arrow-right" class="w-4 h-4" />
                  </div>
                </div>
              </div>
            </article>
          </.link>
        <% end %>
      </div>
    </Layouts.marketing>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    # Get all published blog posts (tags are preloaded in repository)
    posts = Content.list_published_content(scope, :blog)

    # Sort by publish_at descending (newest first), treating nil as oldest
    sorted_posts =
      posts
      |> Enum.sort_by(
        fn post ->
          case post.publish_at do
            nil -> ~U[1970-01-01 00:00:00Z]
            datetime -> datetime
          end
        end,
        {:desc, DateTime}
      )

    base_url = CodeMySpecWeb.Endpoint.url()

    item_list = %{
      "@context" => "https://schema.org",
      "@type" => "ItemList",
      "name" => "CodeMySpec Blog",
      "description" => "Insights on structured AI development and Phoenix applications",
      "url" => "#{base_url}/blog",
      "itemListElement" =>
        sorted_posts
        |> Enum.with_index(1)
        |> Enum.map(fn {post, idx} ->
          %{
            "@type" => "ListItem",
            "position" => idx,
            "url" => "#{base_url}/blog/#{post.slug}",
            "name" => post.title || post.slug
          }
        end)
    }

    breadcrumb = %{
      "@context" => "https://schema.org",
      "@type" => "BreadcrumbList",
      "itemListElement" => [
        %{"@type" => "ListItem", "position" => 1, "name" => "Home", "item" => base_url},
        %{"@type" => "ListItem", "position" => 2, "name" => "Blog"}
      ]
    }

    {:ok,
     socket
     |> assign(:posts, sorted_posts)
     |> assign(:page_title, "Phoenix AI Development Blog — CodeMySpec")
     |> assign(
       :meta_description,
       "Insights on structured AI development, avoiding LLM-generated technical debt, and building production-ready Phoenix applications."
     )
     |> assign(:og_title, "Phoenix AI Development Blog — CodeMySpec")
     |> assign(:og_description, "Insights on structured AI development and building production-ready Phoenix applications.")
     |> assign(:og_image, "#{base_url}/images/og-blog.png")
     |> assign(:canonical_url, "#{base_url}/blog")
     |> assign(:json_ld, Jason.encode!([item_list, breadcrumb]))}
  end

  defp format_date(nil), do: "Draft"

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%B %d, %Y")
  end

  defp extract_excerpt(%{meta_description: meta} = _post) when is_binary(meta) and meta != "",
    do: meta

  defp extract_excerpt(%{processed_content: content}) when is_binary(content) do
    content
    |> strip_html()
    |> String.slice(0..200)
    |> Kernel.<>("...")
  end

  defp extract_excerpt(_), do: "No excerpt available"

  defp strip_html(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
