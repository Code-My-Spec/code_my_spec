defmodule CodeMySpecWeb.ContentHTML do
  use CodeMySpecWeb, :html

  embed_templates "content_html/*"

  def strip_leading_h1(nil), do: nil

  def strip_leading_h1(html) do
    String.replace(html, ~r/<h1[^>]*>.*?<\/h1>\s*/s, "", global: false)
  end

  def format_publish_date(nil), do: ""

  def format_publish_date(datetime) do
    "Published on #{Calendar.strftime(datetime, "%B %d, %Y")}"
  end

  # Widths we generate for each hero via bin/generate-hero-variants.
  # Keep in sync with the script. The master file (no width suffix) is the
  # largest fallback and stays as src for browsers without srcset support.
  @hero_variant_widths [480, 768, 1024]
  @hero_master_width 1376

  def blog_hero_image(%{content_type: :blog, slug: slug} = content) do
    if get_in(content.metadata || %{}, ["metadata", "hero_disabled"]) do
      nil
    else
      CodeMySpecWeb.ImageUrl.image_url("hero-#{slug}.webp")
    end
  end

  def blog_hero_image(_), do: nil

  def blog_hero_srcset(%{content_type: :blog, slug: slug} = content) do
    if get_in(content.metadata || %{}, ["metadata", "hero_disabled"]) do
      nil
    else
      variants =
        Enum.map(@hero_variant_widths, fn w ->
          "#{CodeMySpecWeb.ImageUrl.image_url("hero-#{slug}-#{w}.webp")} #{w}w"
        end)

      master = "#{CodeMySpecWeb.ImageUrl.image_url("hero-#{slug}.webp")} #{@hero_master_width}w"

      Enum.join(variants ++ [master], ", ")
    end
  end

  def blog_hero_srcset(_), do: nil

  # Article column maxes at ~896px on desktop (max-w-4xl), 100vw on mobile.
  def blog_hero_sizes, do: "(min-width: 1024px) 896px, 100vw"

  def format_date(nil), do: "Draft"

  def format_date(datetime) do
    Calendar.strftime(datetime, "%B %d, %Y")
  end

  def extract_excerpt(%{meta_description: meta}) when is_binary(meta) and meta != "", do: meta

  def extract_excerpt(%{processed_content: content}) when is_binary(content) do
    content
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0..200)
    |> Kernel.<>("...")
  end

  def extract_excerpt(_), do: "No excerpt available"
end
