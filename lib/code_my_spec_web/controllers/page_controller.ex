defmodule CodeMySpecWeb.PageController do
  use CodeMySpecWeb, :controller

  def home(conn, _params) do
    copy = CodeMySpecWeb.PageHTML.home_copy()
    meta = copy.meta

    json_ld_list =
      Enum.map(
        [
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
              "url" => "https://codemyspec.com/images/logo-300.png",
              "width" => 300,
              "height" => 300
            },
            "description" => meta.meta_description,
            "founder" => %{
              "@id" => "https://codemyspec.com/author/john-davenport"
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
              "https://www.youtube.com/@codemyspec",
              "https://www.reddit.com/user/johns10davenport/"
            ]
          },
          %{
            "@context" => "https://schema.org",
            "@type" => "SoftwareApplication",
            "@id" => "https://codemyspec.com/#software",
            "name" => "CodeMySpec",
            "url" => "https://codemyspec.com",
            "applicationCategory" => "DeveloperApplication",
            "operatingSystem" => "macOS, Linux, Windows",
            "description" =>
              "Structured AI-assisted development workflows for Phoenix applications. Guides AI agents through design, BDD specs, implementation, and QA.",
            "offers" => %{
              "@type" => "Offer",
              "price" => "0",
              "priceCurrency" => "USD",
              "availability" => "https://schema.org/InStock",
              "priceValidUntil" => "2027-04-05"
            },
            "publisher" => %{
              "@id" => "https://codemyspec.com/#organization"
            }
          }
        ],
        &Jason.encode!/1
      )

    render(conn, :home,
      copy: copy,
      page_title: meta.page_title,
      meta_description: meta.meta_description,
      og_title: meta.og_title,
      og_description: meta.og_description,
      og_image: "#{CodeMySpecWeb.Endpoint.url()}/images/og-home.png",
      canonical_url: meta.canonical_url,
      json_ld_list: json_ld_list
    )
  end

  def code_my_spec(conn, _params) do
    meta = CodeMySpecWeb.PageHTML.code_my_spec_copy().meta
    base_url = CodeMySpecWeb.Endpoint.url()
    canonical = "#{base_url}/products/code-my-spec"

    json_ld_list =
      Enum.map(
        [
          %{
            "@context" => "https://schema.org",
            "@type" => "SoftwareApplication",
            "@id" => "#{canonical}#software",
            "name" => "CodeMySpec",
            "url" => canonical,
            "applicationCategory" => "DeveloperApplication",
            "operatingSystem" => "macOS, Linux, Windows",
            "description" => meta.meta_description,
            "offers" => %{
              "@type" => "Offer",
              "price" => "0",
              "priceCurrency" => "USD",
              "availability" => "https://schema.org/InStock"
            },
            "publisher" => %{
              "@id" => "#{base_url}/#organization"
            }
          },
          %{
            "@context" => "https://schema.org",
            "@type" => "BreadcrumbList",
            "itemListElement" => [
              %{"@type" => "ListItem", "position" => 1, "name" => "Home", "item" => base_url},
              %{
                "@type" => "ListItem",
                "position" => 2,
                "name" => "Products",
                "item" => "#{base_url}/products"
              },
              %{
                "@type" => "ListItem",
                "position" => 3,
                "name" => "CodeMySpec",
                "item" => canonical
              }
            ]
          },
          %{
            "@context" => "https://schema.org",
            "@type" => "FAQPage",
            "mainEntity" => [
              %{
                "@type" => "Question",
                "name" => "I already use Claude Code / Cursor. Why do I need this?",
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" =>
                    "CodeMySpec runs inside Claude Code as a plugin. It adds the lifecycle layer those tools don't have — specs that survive code changes, a requirement graph that keeps the agent on-rails, and browser-based verification after the tests pass."
                }
              },
              %{
                "@type" => "Question",
                "name" => "Isn't this just writing more docs?",
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" =>
                    "Specs aren't docs. They generate tests, constrain the agent, and survive when the code changes. Twenty minutes on a spec saves two hours of prompt iteration."
                }
              },
              %{
                "@type" => "Question",
                "name" => "Am I paying twice — once for Claude and once for you?",
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" =>
                    "No. CodeMySpec doesn't mark up model tokens. You keep your own provider, your own keys, your own bill."
                }
              },
              %{
                "@type" => "Question",
                "name" => "What happens if CodeMySpec shuts down?",
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" =>
                    "Specs are markdown in your repo. Tests are standard Elixir. You own the artifacts. No lock-in."
                }
              },
              %{
                "@type" => "Question",
                "name" => "I'm not on Elixir. Should I care?",
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" =>
                    "The core lifecycle — plugin, MCP servers, requirement graph — works on any stack today. Elixir-native features are the deepest integration. Broader stack support is on the roadmap."
                }
              }
            ]
          }
        ],
        &Jason.encode!/1
      )

    render(conn, :code_my_spec,
      page_title: meta.page_title,
      meta_description: meta.meta_description,
      og_title: meta.og_title,
      og_description: meta.og_description,
      og_image: "#{base_url}/images/og-code-my-spec.png",
      canonical_url: meta.canonical_url,
      json_ld_list: json_ld_list
    )
  end
end
