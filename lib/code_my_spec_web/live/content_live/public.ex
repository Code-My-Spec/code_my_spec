defmodule CodeMySpecWeb.ContentLive.Public do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Content

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.marketing flash={@flash} current_scope={@current_scope}>
      <div id="content-page" phx-hook=".DeepContentRead">
        <.render_template content={@content} tags={@tags} template={@template} />
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
  def mount(%{"slug" => slug}, _session, socket) do
    live_action = socket.assigns.live_action
    content_type = extract_content_type(live_action)
    is_protected = is_protected_route?(live_action)

    scope = socket.assigns.current_scope

    case load_and_verify_content(scope, slug, content_type, is_protected) do
      {:ok, content} ->
        # Content doesn't have tags
        tags = []
        template = Map.get(content.metadata, "template", "default")

        {:ok,
         socket
         |> assign(:current_scope, scope)
         |> assign(:content, content)
         |> assign(:tags, tags)
         |> assign(:template, template)
         |> assign(
           :page_title,
           content.meta_title || content.title || content.slug
         )
         |> assign(:meta_description, content.meta_description)
         |> assign(:og_title, content.og_title)
         |> assign(:og_description, content.og_description)
         |> assign(:og_image, content.og_image)
         |> assign(:canonical_url, build_canonical_url(content, is_protected))
         |> assign(:json_ld, build_json_ld(content, is_protected))}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Content not found")
         |> redirect(to: ~p"/")}

      {:error, :not_published} ->
        {:ok,
         socket
         |> put_flash(:error, "Content not available")
         |> redirect(to: ~p"/")}
    end
  end

  defp extract_content_type(live_action) do
    case live_action do
      action when action in [:blog, :private_blog] -> :blog
      action when action in [:page, :private_page] -> :page
      action when action in [:landing, :private_landing] -> :landing
      action when action in [:documentation, :private_documentation] -> :documentation
    end
  end

  defp is_protected_route?(live_action) do
    live_action in [:private_blog, :private_page, :private_landing, :private_documentation]
  end

  defp load_and_verify_content(scope, slug, content_type, _is_protected) do
    case Content.get_content_by_slug(scope, slug, content_type) do
      nil ->
        {:error, :not_found}

      content ->
        if is_published?(content) do
          {:ok, content}
        else
          {:error, :not_published}
        end
    end
  end

  defp is_published?(content) do
    now = DateTime.utc_now()

    (is_nil(content.publish_at) || DateTime.compare(content.publish_at, now) != :gt) &&
      (is_nil(content.expires_at) || DateTime.compare(content.expires_at, now) == :gt)
  end

  @content_type_paths %{
    blog: "blog",
    page: "pages",
    landing: "landing",
    documentation: "documentation"
  }

  defp build_canonical_url(content, is_protected) do
    prefix = if is_protected, do: "/private", else: ""
    path = Map.fetch!(@content_type_paths, content.content_type)
    "#{prefix}/#{path}/#{content.slug}"
  end

  # Template rendering component
  defp render_template(assigns) do
    case assigns.template do
      "article" -> article_template(assigns)
      "tutorial" -> tutorial_template(assigns)
      _ -> default_template(assigns)
    end
  end

  defp default_template(assigns) do
    ~H"""
    <article class="max-w-4xl mx-auto px-4 py-8">
      <header class="mb-8">
        <h1 class="text-4xl font-bold mb-4">{@content.title || @content.slug}</h1>
        <div :if={@content.content_type == :blog} class="opacity-60 mb-4">
          {format_publish_date(@content.publish_at)}
        </div>
        <div :if={!Enum.empty?(@tags)} class="flex gap-2 flex-wrap">
          <span :for={tag <- @tags} class="badge badge-primary">
            {tag.name}
          </span>
        </div>
      </header>

      <div class="prose prose-lg max-w-none">
        <%= if @content.processed_content do %>
          {raw(strip_leading_h1(@content.processed_content))}
        <% else %>
          <div class="opacity-60 italic">
            Content not available
          </div>
        <% end %>
      </div>
    </article>
    """
  end

  defp article_template(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 py-8">
      <div class="grid grid-cols-1 lg:grid-cols-4 gap-8">
        <aside class="lg:col-span-1 order-2 lg:order-1">
          <div class="sticky top-4">
            <h3 class="font-semibold text-lg mb-2">Tags</h3>
            <div :if={!Enum.empty?(@tags)} class="flex flex-col gap-2">
              <span :for={tag <- @tags} class="badge badge-primary">
                {tag.name}
              </span>
            </div>
            <div :if={Enum.empty?(@tags)} class="opacity-60 text-sm">
              No tags
            </div>
          </div>
        </aside>

        <article class="lg:col-span-3 order-1 lg:order-2">
          <header class="mb-8">
            <h1 class="text-4xl font-bold mb-4">{@content.title || @content.slug}</h1>
            <div class="opacity-60 mb-4">
              {format_publish_date(@content.publish_at)}
            </div>
          </header>

          <div class="prose prose-lg max-w-none">
            <%= if @content.processed_content do %>
              {raw(strip_leading_h1(@content.processed_content))}
            <% else %>
              <div class="opacity-60 italic">
                Content not available
              </div>
            <% end %>
          </div>

          <footer class="mt-12 pt-8 border-t border-base-300">
            <div class="flex gap-4">
              <button class="btn btn-primary">
                Share
              </button>
            </div>
          </footer>
        </article>
      </div>
    </div>
    """
  end

  defp tutorial_template(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 py-8">
      <div class="grid grid-cols-1 lg:grid-cols-4 gap-8">
        <aside class="lg:col-span-1">
          <div class="sticky top-4">
            <h3 class="font-semibold text-lg mb-4">Table of Content</h3>
            <div class="text-sm opacity-60">
              <p class="italic">Auto-generated from content headings</p>
            </div>
          </div>
        </aside>

        <article class="lg:col-span-3">
          <header class="mb-8">
            <div class="badge badge-secondary mb-4">
              Tutorial
            </div>
            <h1 class="text-4xl font-bold mb-4">{@content.title || @content.slug}</h1>
            <div class="opacity-60 mb-4">
              {format_publish_date(@content.publish_at)}
            </div>
            <div :if={!Enum.empty?(@tags)} class="flex gap-2 flex-wrap">
              <span :for={tag <- @tags} class="badge badge-primary badge-sm">
                {tag.name}
              </span>
            </div>
          </header>

          <div class="prose prose-lg max-w-none">
            <%= if @content.processed_content do %>
              {raw(strip_leading_h1(@content.processed_content))}
            <% else %>
              <div class="opacity-60 italic">
                Content not available
              </div>
            <% end %>
          </div>

          <footer class="mt-12 pt-8 border-t border-base-300">
            <div class="alert alert-info">
              <div>
                <h3 class="font-semibold text-lg mb-2">Next Steps</h3>
                <p>Continue learning with related tutorials.</p>
              </div>
            </div>
          </footer>
        </article>
      </div>
    </div>
    """
  end

  defp build_json_ld(content, is_protected) do
    base_url = CodeMySpecWeb.Endpoint.url()
    canonical = build_canonical_url(content, is_protected)
    url = "#{base_url}#{canonical}"

    schema =
      case content.content_type do
        :blog ->
          %{
            "@context" => "https://schema.org",
            "@type" => "Article",
            "headline" => content.title || content.slug,
            "url" => url,
            "datePublished" => format_iso8601(content.publish_at),
            "dateModified" => format_iso8601(content.updated_at),
            "publisher" => %{
              "@type" => "Organization",
              "name" => "CodeMySpec"
            }
          }

        _ ->
          %{
            "@context" => "https://schema.org",
            "@type" => "WebPage",
            "name" => content.title || content.slug,
            "url" => url
          }
      end

    schema =
      if content.meta_description,
        do: Map.put(schema, "description", content.meta_description),
        else: schema

    Jason.encode!(schema)
  end

  defp format_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_iso8601(_), do: nil

  defp strip_leading_h1(nil), do: nil

  defp strip_leading_h1(html) do
    String.replace(html, ~r/\A\s*<h1[^>]*>.*?<\/h1>\s*/s, "", global: false)
  end

  defp format_publish_date(nil), do: ""

  defp format_publish_date(datetime) do
    "Published on #{Calendar.strftime(datetime, "%B %d, %Y")}"
  end
end
