defmodule CodeMySpecWeb.PageController do
  use CodeMySpecWeb, :controller

  def home(conn, _params) do
    meta = %{
      page_title: "CodeMySpec — One Person, a Whole Software Company",
      meta_description:
        "You do the thinking, the machine does the labor. Build real software, run the email and chat your customers reach you on, and grow it — the work of a whole team, without being one.",
      og_title: "CodeMySpec — You do the thinking. The machine does the labor.",
      og_description:
        "Software for operators, not engineers. Build a real app, then keep it running: email on your own domain, live chat with your customers, content and ads that grow it. Drive it yourself, or build it with John.",
      canonical_url: "https://codemyspec.com"
    }

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
            "applicationCategory" => "BusinessApplication",
            "operatingSystem" => "Web-based",
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
      page_title: meta.page_title,
      meta_description: meta.meta_description,
      og_title: meta.og_title,
      og_description: meta.og_description,
      og_image: CodeMySpecWeb.ImageUrl.image_url("og-home.png", CodeMySpecWeb.Endpoint.url()),
      canonical_url: meta.canonical_url,
      json_ld_list: json_ld_list
    )
  end

  def developers(conn, _params) do
    base_url = CodeMySpecWeb.Endpoint.url()
    canonical = "#{base_url}/developers"

    meta = %{
      page_title: "CodeMySpec for Developers — Scaffolding You Own, Not a Platform You Rent",
      meta_description:
        "The free AI build harness that never gets between you and the model. Bring your own keys, own your code, stay in control — a local tool that gives your coding agent the structure to build production software, then gets out of the way.",
      og_title: "Scaffolding you own. Not a platform you rent.",
      og_description:
        "Free forever. Your model, your code, your control. A local harness for your coding agent that builds real software and stays out of the way."
    }

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
            "operatingSystem" => "macOS, Windows",
            "description" => meta.meta_description,
            "screenshot" => %{
              "@type" => "ImageObject",
              "url" => CodeMySpecWeb.ImageUrl.image_url("og-code-my-spec.png", base_url),
              "width" => 1200,
              "height" => 630
            },
            "featureList" =>
              "Claude Code plugin; local MCP server; structured spec-driven build workflow; browser-based verification; bring your own model and API keys with no token markup; standard Phoenix output with no lock-in",
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
                "name" => "Developers",
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
                "name" => "If you don't get between me and the model, why install a thing between me and the model?",
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" =>
                    "It doesn't sit between you and the model — it sits around it. It drives the Claude Code you already run; your keys, your code, and your control stay exactly where they are. It just gives your agent the structure to build real software instead of prototypes that rot."
                }
              },
              %{
                "@type" => "Question",
                "name" => "Am I paying twice — once for Claude and once for you?",
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" =>
                    "No. CodeMySpec never marks up model tokens or proxies your requests. You keep your own provider, your own keys, your own bill. The build tool is free forever."
                }
              },
              %{
                "@type" => "Question",
                "name" => "How can it be free forever? What's the catch?",
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" =>
                    "We make money when your app is running — the hosted layer for email, chat, ads, and analytics that keeps it alive in the world. Not when you build it. So the build tool stays free and we have every reason to stay out of your way."
                }
              },
              %{
                "@type" => "Question",
                "name" => "What happens if CodeMySpec shuts down?",
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" =>
                    "You keep everything. It's a standard Phoenix app on your disk that compiles, tests, and ships without us. Specs are markdown in your repo, tests are standard Elixir. No lock-in."
                }
              },
              %{
                "@type" => "Question",
                "name" => "I'm not on Elixir. Should I care?",
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" =>
                    "The core workflow — plugin, local server, structured build loop — works on any stack today. Elixir and Phoenix are the deepest integration. Broader stack support is on the roadmap."
                }
              }
            ]
          }
        ],
        &Jason.encode!/1
      )

    render(conn, :developers,
      page_title: meta.page_title,
      meta_description: meta.meta_description,
      og_title: meta.og_title,
      og_description: meta.og_description,
      og_image: CodeMySpecWeb.ImageUrl.image_url("og-code-my-spec.png", base_url),
      canonical_url: canonical,
      json_ld_list: json_ld_list
    )
  end

  # The old engineer product page collapsed into /developers (one engineer door).
  # 301 preserves its SEO equity and backlinks.
  def code_my_spec(conn, _params) do
    conn
    |> Plug.Conn.put_status(:moved_permanently)
    |> Phoenix.Controller.redirect(to: "/developers")
  end

  def market_my_spec_redirect(conn, _params) do
    conn
    |> Plug.Conn.put_status(:moved_permanently)
    |> Phoenix.Controller.redirect(external: "https://marketmyspec.com")
  end

end
