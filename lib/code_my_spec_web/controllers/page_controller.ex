defmodule CodeMySpecWeb.PageController do
  use CodeMySpecWeb, :controller

  def home(conn, _params) do
    copy = CodeMySpecWeb.PageHTML.home_copy()
    meta = copy.meta

    json_ld =
      Jason.encode!([
        %{
          "@context" => "https://schema.org",
          "@type" => "WebSite",
          "@id" => "https://codemyspec.com/#website",
          "name" => "CodeMySpec",
          "url" => "https://codemyspec.com",
          "description" => meta.meta_description
        },
        %{
          "@context" => "https://schema.org",
          "@type" => "Organization",
          "@id" => "https://codemyspec.com/#organization",
          "name" => "CodeMySpec",
          "url" => "https://codemyspec.com",
          "logo" => %{
            "@type" => "ImageObject",
            "url" => "https://codemyspec.com/images/logo.svg"
          },
          "description" => meta.meta_description,
          "founder" => %{
            "@type" => "Person",
            "name" => "John Davenport"
          },
          "contactPoint" => %{
            "@type" => "ContactPoint",
            "contactType" => "customer support",
            "url" => "https://codemyspec.com/pages/about"
          },
          "sameAs" => [
            "https://github.com/code-my-spec",
            "https://www.linkedin.com/in/john-davenport-software/",
            "https://www.linkedin.com/company/112625303/",
            "https://x.com/johns10d",
            "https://www.facebook.com/johns10davenport",
            "https://www.facebook.com/profile.php?id=61574278441856",
            "https://www.youtube.com/@codemyspec"
          ]
        },
        %{
          "@context" => "https://schema.org",
          "@type" => "SoftwareApplication",
          "name" => "CodeMySpec",
          "url" => "https://codemyspec.com",
          "applicationCategory" => "DeveloperApplication",
          "operatingSystem" => "macOS, Linux, Windows",
          "description" => "Structured AI-assisted development workflows for Phoenix applications. Guides AI agents through design, BDD specs, implementation, and QA.",
          "offers" => %{
            "@type" => "Offer",
            "price" => "0",
            "priceCurrency" => "USD",
            "availability" => "https://schema.org/InStock"
          },
          "publisher" => %{
            "@id" => "https://codemyspec.com/#organization"
          }
        }
      ])

    render(conn, :home,
      copy: copy,
      page_title: meta.page_title,
      meta_description: meta.meta_description,
      og_title: meta.og_title,
      og_description: meta.og_description,
      og_image: "#{CodeMySpecWeb.Endpoint.url()}/images/og-home.png",
      canonical_url: meta.canonical_url,
      json_ld: json_ld
    )
  end
end
