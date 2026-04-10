defmodule CodeMySpecWeb.ContentHTML do
  use CodeMySpecWeb, :html

  embed_templates "content_html/*"

  def strip_leading_h1(nil), do: nil

  def strip_leading_h1(html) do
    String.replace(html, ~r/\A\s*<h1[^>]*>.*?<\/h1>\s*/s, "", global: false)
  end

  def format_publish_date(nil), do: ""

  def format_publish_date(datetime) do
    "Published on #{Calendar.strftime(datetime, "%B %d, %Y")}"
  end

  def blog_hero_image(%{content_type: :blog, slug: slug}) do
    path = "images/hero-#{slug}.png"

    if File.exists?(Application.app_dir(:code_my_spec, "priv/static/#{path}")),
      do: "/#{path}",
      else: nil
  end

  def blog_hero_image(_), do: nil
end
