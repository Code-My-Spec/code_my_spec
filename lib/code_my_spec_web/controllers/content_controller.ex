defmodule CodeMySpecWeb.ContentController do
  use CodeMySpecWeb, :controller

  alias CodeMySpec.Content
  alias CodeMySpec.Content.ContentRepository

  @index_config %{
    blog: %{
      badge: "Blog",
      title: "Latest Articles",
      description: "Insights on structured AI development, avoiding LLM-generated technical debt, and building production-ready Phoenix applications.",
      icon: "hero-document-text",
      empty_message: "No posts yet",
      page_title: "Phoenix AI Development Blog — CodeMySpec",
      og_image_suffix: "blog",
      item_path_prefix: "/blog",
      schema_name: "CodeMySpec Blog"
    },
    documentation: %{
      badge: "Documentation",
      title: "Documentation",
      description: "Technical guides, API references, and tutorials for getting the most out of CodeMySpec.",
      icon: "hero-book-open",
      empty_message: "No documentation yet",
      page_title: "Documentation — CodeMySpec",
      og_image_suffix: "docs",
      item_path_prefix: "/documentation",
      schema_name: "CodeMySpec Documentation"
    },
    page: %{
      badge: "Pages",
      title: "Pages",
      description: "Reviews, comparisons, and resources for AI-assisted development tools and workflows.",
      icon: "hero-squares-2x2",
      empty_message: "No pages yet",
      page_title: "Pages — CodeMySpec",
      og_image_suffix: "pages",
      item_path_prefix: "/pages",
      schema_name: "CodeMySpec Pages"
    }
  }

  def index(conn, _params) do
    content_type = index_content_type(conn.private.phoenix_action)
    config = Map.fetch!(@index_config, content_type)
    scope = conn.assigns[:current_scope]
    base_url = CodeMySpecWeb.Endpoint.url()

    posts =
      scope
      |> Content.list_published_content(content_type)
      |> Enum.sort_by(
        fn post ->
          case post.publish_at do
            nil -> ~U[1970-01-01 00:00:00Z]
            datetime -> datetime
          end
        end,
        {:desc, DateTime}
      )

    item_list = %{
      "@context" => "https://schema.org",
      "@type" => "ItemList",
      "name" => config.schema_name,
      "description" => config.description,
      "url" => "#{base_url}#{config.item_path_prefix}",
      "itemListElement" =>
        posts
        |> Enum.with_index(1)
        |> Enum.map(fn {post, idx} ->
          %{
            "@type" => "ListItem",
            "position" => idx,
            "url" => "#{base_url}#{config.item_path_prefix}/#{post.slug}",
            "name" => post.title || post.slug
          }
        end)
    }

    breadcrumb = %{
      "@context" => "https://schema.org",
      "@type" => "BreadcrumbList",
      "itemListElement" => [
        %{"@type" => "ListItem", "position" => 1, "name" => "Home", "item" => base_url},
        %{"@type" => "ListItem", "position" => 2, "name" => config.badge, "item" => "#{base_url}#{config.item_path_prefix}"}
      ]
    }

    # Add Blog entity for blog index to provide publisher linkage
    schemas =
      if content_type == :blog do
        blog_entity = %{
          "@context" => "https://schema.org",
          "@type" => "Blog",
          "@id" => "#{base_url}/blog#blog",
          "url" => "#{base_url}/blog",
          "name" => config.schema_name,
          "description" => config.description,
          "publisher" => %{"@id" => "#{base_url}/#organization"},
          "inLanguage" => "en-US"
        }

        [item_list, blog_entity, breadcrumb]
      else
        [item_list, breadcrumb]
      end

    render(conn, :index,
      posts: posts,
      config: config,
      page_title: config.page_title,
      meta_description: config.description,
      og_title: config.page_title,
      og_description: config.description,
      og_image: "#{base_url}/images/og-#{config.og_image_suffix}.png",
      canonical_url: "#{base_url}#{config.item_path_prefix}",
      json_ld: Jason.encode!(schemas)
    )
  end

  def blog_index(conn, params), do: index(conn, params)
  def documentation_index(conn, params), do: index(conn, params)
  def pages_index(conn, params), do: index(conn, params)

  defp index_content_type(:blog_index), do: :blog
  defp index_content_type(:documentation_index), do: :documentation
  defp index_content_type(:pages_index), do: :page

  def show(conn, %{"slug" => slug}) do
    content_type = content_type_from_action(conn.private.phoenix_action)
    is_protected = protected_action?(conn.private.phoenix_action)
    scope = conn.assigns[:current_scope]

    case load_and_verify_content(scope, slug, content_type, is_protected) do
      {:ok, content} ->
        template = get_in(content.metadata || %{}, ["metadata", "template"]) || "default"
        base_url = CodeMySpecWeb.Endpoint.url()
        canonical = build_canonical_url(content, is_protected)
        is_article = content.content_type == :blog
        series_info = build_series_info(content)

        render(conn, template_action(template),
          content: content,
          tags: [],
          template: template,
          series_info: series_info,
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

  defp protected_action?(action) do
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
        if published?(content) do
          {:ok, content}
        else
          {:error, :not_published}
        end
    end
  end

  defp published?(content) do
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

  defp word_count(nil), do: 0

  defp word_count(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

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
        "url" => "#{base_url}/images/logo-300.png",
        "width" => 300,
        "height" => 300
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
          tag_names = Enum.map(content.tags || [], & &1.name)
          word_count = word_count(content.processed_content)
          category = get_in(content.metadata || %{}, ["metadata", "category"])

          blog_posting =
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
              "mainEntityOfPage" => %{"@type" => "WebPage", "@id" => url},
              "inLanguage" => "en-US",
              "wordCount" => word_count
            }
            |> then(fn schema ->
              if tag_names != [], do: Map.put(schema, "keywords", Enum.join(tag_names, ", ")), else: schema
            end)
            |> then(fn schema ->
              if category, do: Map.put(schema, "articleSection", category), else: schema
            end)

          [blog_posting]

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
              "mainEntityOfPage" => %{"@type" => "WebPage", "@id" => url},
              "proficiencyLevel" => "Beginner",
              "articleSection" => "Documentation"
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

  defp build_series_info(content) do
    series_name = get_in(content.metadata || %{}, ["metadata", "series"])

    case series_name do
      nil ->
        nil

      name ->
        posts = ContentRepository.list_series_posts(name)

        if length(posts) > 1 do
          current_idx = Enum.find_index(posts, &(&1.slug == content.slug))

          %{
            name: name,
            posts: posts,
            current_slug: content.slug,
            prev_post: if(current_idx && current_idx > 0, do: Enum.at(posts, current_idx - 1)),
            next_post: if(current_idx, do: Enum.at(posts, current_idx + 1))
          }
        else
          nil
        end
    end
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
