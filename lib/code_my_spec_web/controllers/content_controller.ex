defmodule CodeMySpecWeb.ContentController do
  use CodeMySpecWeb, :controller

  alias CodeMySpec.Content

  def show(conn, %{"slug" => slug}) do
    content_type = content_type_from_action(conn.private.phoenix_action)
    is_protected = is_protected_action?(conn.private.phoenix_action)
    scope = conn.assigns[:current_scope]

    case load_and_verify_content(scope, slug, content_type, is_protected) do
      {:ok, content} ->
        template = Map.get(content.metadata || %{}, "template", "default")
        base_url = CodeMySpecWeb.Endpoint.url()
        canonical = build_canonical_url(content, is_protected)
        is_article = content.content_type == :blog

        render(conn, template_action(template),
          content: content,
          tags: [],
          template: template,
          page_title: content.meta_title || content.title || content.slug,
          meta_description: content.meta_description,
          og_title: content.og_title,
          og_description: content.og_description,
          og_image: content.og_image || blog_og_image(content, base_url),
          og_type: if(is_article, do: "article", else: "website"),
          article_published_time: if(is_article, do: format_iso8601(content.publish_at)),
          canonical_url: base_url <> canonical,
          json_ld: build_json_ld(content, is_protected)
        )

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Content not found")
        |> redirect(to: ~p"/")
    end
  end

  # Route all content actions through show/2
  def blog(conn, params), do: show(conn, params)
  def page(conn, params), do: show(conn, params)
  def landing(conn, params), do: show(conn, params)
  def documentation(conn, params), do: show(conn, params)
  def private_blog(conn, params), do: show(conn, params)
  def private_page(conn, params), do: show(conn, params)
  def private_landing(conn, params), do: show(conn, params)
  def private_documentation(conn, params), do: show(conn, params)

  # --- Private helpers ---

  defp content_type_from_action(action) do
    case action do
      a when a in [:blog, :private_blog] -> :blog
      a when a in [:page, :private_page] -> :page
      a when a in [:landing, :private_landing] -> :landing
      a when a in [:documentation, :private_documentation] -> :documentation
    end
  end

  defp is_protected_action?(action) do
    action in [:private_blog, :private_page, :private_landing, :private_documentation]
  end

  defp template_action("article"), do: :article
  defp template_action("tutorial"), do: :tutorial
  defp template_action(_), do: :default

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

  defp blog_og_image(%{content_type: :blog, slug: slug}, base_url) do
    "#{base_url}/images/og-blog-#{slug}.png"
  end

  defp blog_og_image(_, _), do: nil

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

  defp format_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_iso8601(_), do: nil

  defp extract_tool_name(nil), do: "Software"

  defp extract_tool_name(title) do
    case Regex.run(~r/^(.+?)\s+in\s+\d{4}/, title) do
      [_, name] -> name
      _ -> title |> String.split(":") |> List.first() |> String.trim()
    end
  end

  @type_labels %{
    blog: "Blog",
    page: "Pages",
    landing: "Landing",
    documentation: "Documentation"
  }

  defp build_json_ld(content, is_protected) do
    base_url = CodeMySpecWeb.Endpoint.url()
    canonical = build_canonical_url(content, is_protected)
    url = base_url <> canonical
    og_image = content.og_image || blog_og_image(content, base_url) || "#{base_url}/images/og-default.png"

    author = %{
      "@type" => "Person",
      "@id" => "#{base_url}/author/john-davenport",
      "name" => "John Davenport",
      "url" => "#{base_url}/author/john-davenport"
    }

    publisher = %{
      "@type" => "Organization",
      "@id" => "#{base_url}/#organization",
      "name" => "CodeMySpec",
      "logo" => %{
        "@type" => "ImageObject",
        "url" => "#{base_url}/images/logo.svg",
        "width" => 512,
        "height" => 512
      }
    }

    image = %{
      "@type" => "ImageObject",
      "url" => og_image,
      "width" => 1200,
      "height" => 630
    }

    schemas =
      case content.content_type do
        :blog ->
          [
            %{
              "@context" => "https://schema.org",
              "@type" => "BlogPosting",
              "@id" => url,
              "headline" => content.title || content.slug,
              "url" => url,
              "image" => image,
              "datePublished" => format_iso8601(content.publish_at),
              "dateModified" => format_iso8601(content.updated_at),
              "author" => author,
              "publisher" => publisher,
              "mainEntityOfPage" => %{"@type" => "WebPage", "@id" => url}
            }
          ]

        :documentation ->
          [
            %{
              "@context" => "https://schema.org",
              "@type" => "TechArticle",
              "@id" => url,
              "headline" => content.title || content.slug,
              "url" => url,
              "image" => image,
              "datePublished" => format_iso8601(content.publish_at),
              "dateModified" => format_iso8601(content.updated_at),
              "author" => author,
              "publisher" => publisher,
              "mainEntityOfPage" => %{"@type" => "WebPage", "@id" => url}
            }
          ]

        :page ->
          if String.contains?(content.slug || "", "review") do
            tool_name = extract_tool_name(content.title)

            [
              %{
                "@context" => "https://schema.org",
                "@type" => "Review",
                "@id" => url,
                "name" => content.title || content.slug,
                "url" => url,
                "datePublished" => format_iso8601(content.publish_at),
                "dateModified" => format_iso8601(content.updated_at),
                "author" => author,
                "publisher" => publisher,
                "itemReviewed" => %{
                  "@type" => "SoftwareApplication",
                  "name" => tool_name,
                  "applicationCategory" => "DeveloperApplication"
                }
              }
            ]
          else
            [
              %{
                "@context" => "https://schema.org",
                "@type" => "WebPage",
                "@id" => url,
                "name" => content.title || content.slug,
                "url" => url,
                "datePublished" => format_iso8601(content.publish_at),
                "dateModified" => format_iso8601(content.updated_at),
                "author" => author,
                "publisher" => publisher
              }
            ]
          end

        _ ->
          [
            %{
              "@context" => "https://schema.org",
              "@type" => "WebPage",
              "@id" => url,
              "name" => content.title || content.slug,
              "url" => url
            }
          ]
      end

    schemas =
      Enum.map(schemas, fn schema ->
        if content.meta_description,
          do: Map.put(schema, "description", content.meta_description),
          else: schema
      end)

    breadcrumb = build_breadcrumb(content, base_url)

    Jason.encode!(schemas ++ [breadcrumb])
  end

  defp build_breadcrumb(content, base_url) do
    type_label =
      Map.get(@type_labels, content.content_type, content.content_type |> to_string() |> String.capitalize())

    type_path = Map.fetch!(@content_type_paths, content.content_type)

    %{
      "@context" => "https://schema.org",
      "@type" => "BreadcrumbList",
      "itemListElement" => [
        %{
          "@type" => "ListItem",
          "position" => 1,
          "name" => "Home",
          "item" => base_url
        },
        %{
          "@type" => "ListItem",
          "position" => 2,
          "name" => type_label,
          "item" => "#{base_url}/#{type_path}"
        },
        %{
          "@type" => "ListItem",
          "position" => 3,
          "name" => content.title || content.slug,
          "item" => "#{base_url}/#{type_path}/#{content.slug}"
        }
      ]
    }
  end
end
