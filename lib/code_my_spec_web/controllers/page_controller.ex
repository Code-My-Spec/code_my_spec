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
              "A set of AI harnesses that help one person build, sell, and support real software. Build free with your own AI keys; run and grow it for $100 a month per user.",
            "offers" => %{
              "@type" => "AggregateOffer",
              "priceCurrency" => "USD",
              "lowPrice" => "0",
              "highPrice" => "100",
              "offerCount" => "2",
              "offers" => [
                %{
                  "@type" => "Offer",
                  "name" => "Build",
                  "price" => "0",
                  "priceCurrency" => "USD",
                  "availability" => "https://schema.org/InStock"
                },
                %{
                  "@type" => "Offer",
                  "name" => "Operate & Grow",
                  "price" => "100",
                  "priceCurrency" => "USD",
                  "availability" => "https://schema.org/InStock"
                }
              ]
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
                "name" =>
                  "If you don't get between me and the model, why install a thing between me and the model?",
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

  def install(conn, _params) do
    base_url = CodeMySpecWeb.Endpoint.url()
    canonical = "#{base_url}/install"

    meta = %{
      page_title: "Install CodeMySpec — Free Forever",
      meta_description:
        "Install the CodeMySpec build harness in a few minutes — a local server plus a Claude Code plugin. Bring your own keys, own your code, free forever.",
      og_title: "Install CodeMySpec — free forever",
      og_description:
        "Two pieces, a few minutes. A local server and a Claude Code plugin. Your model, your code, your control — free forever."
    }

    json_ld_list =
      Enum.map(
        [
          %{
            "@context" => "https://schema.org",
            "@type" => "HowTo",
            "name" => "Install CodeMySpec",
            "description" => meta.meta_description,
            "totalTime" => "PT5M",
            "step" => [
              %{
                "@type" => "HowToStep",
                "position" => 1,
                "name" => "Install the server",
                "text" =>
                  "On macOS (Apple Silicon): brew install Code-My-Spec/tap/codemyspec, then brew services start codemyspec. On Windows (x64): run the cms-setup-x64.msi installer."
              },
              %{
                "@type" => "HowToStep",
                "position" => 2,
                "name" => "Install the plugin",
                "text" =>
                  "In Claude Code: /plugin marketplace add Code-My-Spec/plugins, then /plugin install codemyspec@codemyspec."
              },
              %{
                "@type" => "HowToStep",
                "position" => 3,
                "name" => "First run",
                "text" =>
                  "In your Phoenix project, run /codemyspec:init auth, then tell the agent to use the get_next_requirement tool."
              }
            ]
          },
          %{
            "@context" => "https://schema.org",
            "@type" => "SoftwareApplication",
            "@id" => "#{canonical}#software",
            "name" => "CodeMySpec",
            "url" => canonical,
            "applicationCategory" => "DeveloperApplication",
            "operatingSystem" => "macOS, Windows",
            "description" => meta.meta_description,
            "offers" => %{
              "@type" => "Offer",
              "price" => "0",
              "priceCurrency" => "USD",
              "availability" => "https://schema.org/InStock"
            },
            "publisher" => %{"@id" => "#{base_url}/#organization"}
          }
        ],
        &Jason.encode!/1
      )

    render(conn, :install,
      page_title: meta.page_title,
      meta_description: meta.meta_description,
      og_title: meta.og_title,
      og_description: meta.og_description,
      og_image: CodeMySpecWeb.ImageUrl.image_url("og-code-my-spec.png", base_url),
      canonical_url: canonical,
      json_ld_list: json_ld_list
    )
  end

  def pricing(conn, _params) do
    base_url = CodeMySpecWeb.Endpoint.url()
    canonical = "#{base_url}/pricing"

    meta = %{
      page_title: "CodeMySpec Pricing — Free to Build, $100/mo to Run",
      meta_description:
        "Build for free with the CodeMySpec harness, content engine included. Run and grow your software for $100 a month per user, or have John build it with you from $500.",
      og_title: "Free to build. $100 a month to run.",
      og_description:
        "The build and content harnesses are free forever, with your own AI keys and no markup. Pay $100 a month per user when your software is live, or have John build it with you from $500."
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
            "applicationCategory" => "BusinessApplication",
            "operatingSystem" => "Web-based, macOS, Windows",
            "description" =>
              "A set of model harnesses that help one person build, sell, and support real software.",
            "offers" => %{
              "@type" => "AggregateOffer",
              "priceCurrency" => "USD",
              "lowPrice" => "0",
              "highPrice" => "100",
              "offerCount" => "2",
              "offers" => [
                %{
                  "@type" => "Offer",
                  "name" => "Build",
                  "description" =>
                    "The build and content harnesses, free forever. Bring your own AI keys, own everything you make.",
                  "price" => "0",
                  "priceCurrency" => "USD",
                  "availability" => "https://schema.org/InStock"
                },
                %{
                  "@type" => "Offer",
                  "name" => "Operate & Grow",
                  "description" =>
                    "Email on your own domain, live chat, content publishing, Google Ads, and conversion reporting. Per user, per month.",
                  "price" => "100",
                  "priceCurrency" => "USD",
                  "availability" => "https://schema.org/InStock"
                }
              ]
            },
            "publisher" => %{"@id" => "#{base_url}/#organization"}
          },
          %{
            "@context" => "https://schema.org",
            "@type" => "Service",
            "@id" => "#{canonical}#built-with-you",
            "name" => "CodeMySpec — Built with you",
            "serviceType" => "Software development",
            "description" =>
              "John runs the CodeMySpec harness on your project and delivers working software. Scoped and quoted after a conversation, $500 minimum.",
            "provider" => %{"@id" => "#{base_url}/#organization"},
            "offers" => %{
              "@type" => "Offer",
              "priceCurrency" => "USD",
              "priceSpecification" => %{
                "@type" => "PriceSpecification",
                "minPrice" => "500",
                "priceCurrency" => "USD"
              },
              "availability" => "https://schema.org/InStock"
            }
          },
          %{
            "@context" => "https://schema.org",
            "@type" => "BreadcrumbList",
            "itemListElement" => [
              %{"@type" => "ListItem", "position" => 1, "name" => "Home", "item" => base_url},
              %{"@type" => "ListItem", "position" => 2, "name" => "Pricing", "item" => canonical}
            ]
          }
        ],
        &Jason.encode!/1
      )

    render(conn, :pricing,
      page_title: meta.page_title,
      meta_description: meta.meta_description,
      og_title: meta.og_title,
      og_description: meta.og_description,
      og_image: CodeMySpecWeb.ImageUrl.image_url("og-pricing.png", base_url),
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
