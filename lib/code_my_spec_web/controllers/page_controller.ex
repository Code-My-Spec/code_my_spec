defmodule CodeMySpecWeb.PageController do
  use CodeMySpecWeb, :controller

  def home(conn, _params) do
    copy = CodeMySpecWeb.PageHTML.home_copy()
    meta = copy.meta

    json_ld =
      Jason.encode!(%{
        "@context" => "https://schema.org",
        "@type" => "WebSite",
        "name" => "CodeMySpec",
        "url" => "https://codemyspec.com",
        "description" => meta.meta_description
      })

    render(conn, :home,
      copy: copy,
      page_title: meta.page_title,
      meta_description: meta.meta_description,
      og_title: meta.og_title,
      og_description: meta.og_description,
      canonical_url: meta.canonical_url,
      json_ld: json_ld
    )
  end
end
