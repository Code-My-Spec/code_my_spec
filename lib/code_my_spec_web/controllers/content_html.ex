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

  def blog_hero_image(%{content_type: :blog, slug: slug}) do
    CodeMySpecWeb.ImageUrl.image_url("hero-#{slug}.webp")
  end

  def blog_hero_image(_), do: nil

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
