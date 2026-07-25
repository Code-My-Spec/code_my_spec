defmodule CodeMySpecWeb.PageController do
  use CodeMySpecWeb, :controller

  # Rendered in the visible FAQ section on the homepage AND serialized into
  # FAQPage JSON-LD — one source so the schema never claims text the page
  # doesn't show.
  @home_faqs [
    %{
      q: "What is CodeMySpec?",
      a:
        "A set of AI harnesses that help one person build, sell, and support real software. " <>
          "You build the app with the model, run the email and chat your customers reach you on, " <>
          "and do the outreach that grows it — the work of a whole team, from one seat."
    },
    %{
      q: "Do I need to know how to code?",
      a:
        "No. CodeMySpec is built for operators, not engineers. You bring the judgment about " <>
          "your business; the model does the building and the running, with you calling the shots. " <>
          "Developers who'd rather wire it up themselves can use the build harness free."
    },
    %{
      q: "How much does it cost?",
      a:
        "Building is free forever — bring your own AI keys and pay the AI company directly; " <>
          "we never mark up your tokens. Running your software — email on your own domain, live " <>
          "chat, content publishing, ads, and conversion reporting — is $100 a month per user. " <>
          "Want it built with you? John scopes and quotes the work, from $500."
    },
    %{
      q: "Is the free tier a trial?",
      a:
        "No. Nothing expires and there's no credit card. It's the same harness John uses to " <>
          "run CodeMySpec itself."
    },
    %{
      q: "What happens if I stop paying?",
      a:
        "The hosted services stop — email, chat, publishing, reporting. Your software, your " <>
          "code, and your content stay yours. There's no lock-in to unwind; the $100 was never " <>
          "rent on your own app."
    }
  ]

  def home(conn, _params) do
    meta = %{
      page_title: "CodeMySpec — One Person, a Whole Software Company",
      meta_description:
        "CodeMySpec is a set of AI harnesses that help one person build, sell, and support real software. You do the thinking; the machine does the labor.",
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
              "contactType" => "customer service",
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
            "operatingSystem" => "Web-based, macOS, Windows",
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
            "publisher" => %{
              "@id" => "https://codemyspec.com/#organization"
            }
          },
          %{
            "@context" => "https://schema.org",
            "@type" => "FAQPage",
            "mainEntity" =>
              Enum.map(@home_faqs, fn faq ->
                %{
                  "@type" => "Question",
                  "name" => faq.q,
                  "acceptedAnswer" => %{"@type" => "Answer", "text" => faq.a}
                }
              end)
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
      json_ld_list: json_ld_list,
      faqs: @home_faqs
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
          # Reference the canonical SoftwareApplication entity defined on the
          # homepage instead of duplicating (and drifting from) it here.
          %{
            "@context" => "https://schema.org",
            "@type" => "SoftwareApplication",
            "@id" => "#{base_url}/#software",
            "name" => "CodeMySpec",
            "url" => canonical
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
          },
          %{
            "@context" => "https://schema.org",
            "@type" => "FAQPage",
            "mainEntity" => [
              %{
                "@type" => "Question",
                "name" => "How much does CodeMySpec cost?",
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" =>
                    "Building is free forever. Running your software — customer email on your domain, live chat, content publishing, ads, and conversion reporting — is $100 a month per user. If you want it built with you, John quotes the work after a conversation, with a $500 minimum."
                }
              },
              %{
                "@type" => "Question",
                "name" => "Is the free tier a trial?",
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" =>
                    "No. The build harness and the content engine are free forever, with no credit card and nothing that expires. It isn't a stripped-down demo — it's the same harness John uses to run CodeMySpec itself."
                }
              },
              %{
                "@type" => "Question",
                "name" => "Am I paying for the AI on top of this?",
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" =>
                    "You bring your own AI keys and pay the AI company directly for what you use. CodeMySpec never marks up model tokens or proxies your requests — your keys, your bill, your code."
                }
              },
              %{
                "@type" => "Question",
                "name" => "What does \"per user\" mean?",
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" =>
                    "A user is a person on your account doing the work — answering chat, sending email, publishing content. If that's just you, Operate & Grow costs $100 a month, total. Add seats only when more hands are actually in the tools."
                }
              },
              %{
                "@type" => "Question",
                "name" => "What does the $500 minimum on Built with you cover?",
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" =>
                    "It's a floor, not a package. You bring what you're trying to run, John scopes it in a real conversation and quotes a real number. The work is done the same way as self-serve — specs, tests, verification — and you own everything when it ships."
                }
              },
              %{
                "@type" => "Question",
                "name" => "What happens if I stop paying?",
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" =>
                    "The hosted services stop — email, chat, publishing, reporting. Your software, your code, and your content stay yours. There's no lock-in to unwind; the $100 was never rent on your own app."
                }
              },
              %{
                "@type" => "Question",
                "name" => "Can I use it for internal tools instead of software I sell?",
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" =>
                    "Yes. Build and Operate work the same whether the software faces customers or your own crew. Plenty of operators need a tool that fits their workflow, not a product to sell — that counts."
                }
              }
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
  # Answer-first on purpose: each answer's first sentence is a complete, liftable
  # response, because a retrieval system pulls the passage, not the page. Claims
  # here are bounded by the feature-research honesty ledger — Claude Code is the
  # flagship and Codex/Antigravity are early, the server ships for macOS and
  # Windows only, and QA outcomes are cited as case-study results.
  @product_faqs [
    %{
      q: "What is CodeMySpec?",
      a:
        "CodeMySpec is a requirements-driven development harness for building real software with AI. " <>
          "It runs as a plugin inside your AI coding agent and walks that agent through a full lifecycle " <>
          "for every piece of your app — specification, tests, implementation, review, and QA, in the " <>
          "right order. Your specs are plain markdown and your tests are standard ExUnit, both in your " <>
          "own repository."
    },
    %{
      q: "Does CodeMySpec replace Cursor, Claude Code, or Copilot?",
      a:
        "No — CodeMySpec runs inside them. Those are the coding agent that writes the code; CodeMySpec " <>
          "is the harness on top that adds specs, architecture enforcement, verification, and QA. The " <>
          "tools CodeMySpec is genuinely an alternative to are the app builders like Lovable and Replit: " <>
          "it is the engineer's version of that promise, where the result is code you can still maintain."
    },
    %{
      q: "What AI agents does CodeMySpec work with?",
      a:
        "CodeMySpec works with Claude Code, OpenAI Codex, and Google Antigravity. Claude Code has the " <>
          "deepest integration and is the flagship; Codex and Antigravity are early. It works across " <>
          "agents because the harness is not the plugin — it is a local server on your machine, and each " <>
          "plugin is a thin adapter that points your agent at it."
    },
    %{
      q: "Is CodeMySpec only for Phoenix and Elixir?",
      a:
        "No. The core lifecycle — the requirement graph, specs, BDD scenarios, and browser QA — works on " <>
          "any stack through your AI agent. Phoenix and Elixir are the deepest integration, where " <>
          "CodeMySpec understands 16 component types and builds idiomatic, OTP-aware code."
    },
    %{
      q: "Does CodeMySpec lock me in?",
      a:
        "No. Your specifications are plain markdown and your tests are standard ExUnit, both in your own " <>
          "repository, and you bring your own model and API keys with no markup on tokens. There is no " <>
          "proprietary spec format, no custom test runner, and no DSL to learn. If you stopped using " <>
          "CodeMySpec tomorrow, you would keep every artifact of value."
    },
    %{
      q: "How does CodeMySpec catch bugs that tests miss?",
      a:
        "A QA agent drives your running application in a real browser — per story, per user journey, or " <>
          "across the whole app — and records an audited trail of every attempt. Passing tests are not " <>
          "the same as working software: unit tests miss integration failures, broken flows, and UI " <>
          "regressions that look correct in the code and break in front of a user."
    },
    %{
      q: "What does CodeMySpec verify before code ships?",
      a:
        "Every time the agent stops, CodeMySpec compiles the code, runs Credo, runs the tests, and runs " <>
          "the Spex specs, and it can block the agent from continuing on failure. Blocking is " <>
          "configurable per check: off, block on any failure, block only on changed files, or never " <>
          "block. The agent cannot quietly leave the build broken or skip the tests."
    },
    %{
      q: "What does CodeMySpec cost?",
      a:
        "Building is free. The harness and the local server cost nothing to run with your own AI keys, " <>
          "and CodeMySpec never marks up model tokens. The hosted Operate and Grow layer is $100 per " <>
          "month per user, and a done-with-you build engagement starts at $500, quoted."
    },
    %{
      q: "Who is CodeMySpec for?",
      a:
        "CodeMySpec is for engineers who ship and maintain the code they build — senior Phoenix and " <>
          "Elixir engineers, Elixir agencies, and solo technical founders shipping a real product. It is " <>
          "not for throwaway prototypes. If you are throwing it away, prompt directly; if you are " <>
          "shipping it, you need the harness."
    }
  ]

  def product(conn, _params) do
    base_url = CodeMySpecWeb.Endpoint.url()
    canonical = "#{base_url}/product"

    meta = %{
      page_title: "CodeMySpec — The AI Development Harness for Software You Can Maintain",
      meta_description:
        "CodeMySpec is a spec-driven development harness that runs inside your AI coding agent. " <>
          "Specs, tests, architecture, and QA on one requirement graph. Bring your own model, no lock-in.",
      og_title: "The harness that turns AI coding into a system",
      og_description:
        "Specs, tests, architecture enforcement, verification, and browser QA on one requirement graph — " <>
          "inside the coding agent you already use. Free to build."
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
            "featureList" =>
              "Requirement graph that sequences the work; specification-first workflow; 16 Phoenix " <>
                "component types; dependency-graph validation and architecture enforcement; Three " <>
                "Amigos BDD scenarios compiled to ExUnit; automatic compile, Credo, test and Spex " <>
                "verification on every agent stop; agentic browser QA against the running app; " <>
                "plugins for Claude Code, OpenAI Codex and Google Antigravity; markdown specs and " <>
                "ExUnit tests in your own repository; bring your own model and keys with no token markup",
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
            ],
            "publisher" => %{"@id" => "#{base_url}/#organization"}
          },
          %{
            "@context" => "https://schema.org",
            "@type" => "BreadcrumbList",
            "itemListElement" => [
              %{"@type" => "ListItem", "position" => 1, "name" => "Home", "item" => base_url},
              %{"@type" => "ListItem", "position" => 2, "name" => "Product", "item" => canonical}
            ]
          },
          %{
            "@context" => "https://schema.org",
            "@type" => "FAQPage",
            "mainEntity" =>
              Enum.map(@product_faqs, fn faq ->
                %{
                  "@type" => "Question",
                  "name" => faq.q,
                  "acceptedAnswer" => %{"@type" => "Answer", "text" => faq.a}
                }
              end)
          }
        ],
        &Jason.encode!/1
      )

    render(conn, :product,
      page_title: meta.page_title,
      meta_description: meta.meta_description,
      og_title: meta.og_title,
      og_description: meta.og_description,
      og_image: CodeMySpecWeb.ImageUrl.image_url("og-product.png", base_url),
      canonical_url: canonical,
      json_ld_list: json_ld_list,
      faqs: @product_faqs
    )
  end

  # Maturity language is load-bearing here. Claude Code is the flagship; Codex
  # and Antigravity are early, and the per-agent gaps below come from the plugin
  # READMEs rather than the marketing narrative. Install commands deliberately
  # live on /install only — the Codex and Antigravity marketplace invocations are
  # flagged unverified in their READMEs, and publishing an install command that
  # dead-ends costs more trust than the page earns.
  @agent_faqs [
    %{
      q: "What AI agents does CodeMySpec work with?",
      a:
        "CodeMySpec works with Claude Code, OpenAI Codex, and Google Antigravity. Claude Code has " <>
          "the deepest integration and is the flagship; Codex and Antigravity are early. All three " <>
          "run on your own API keys with no markup on model tokens."
    },
    %{
      q: "How can one tool support several different agents?",
      a:
        "Because the harness is not the plugin. The harness is a local server on your machine, and " <>
          "each plugin is a thin adapter that registers the server's tools and forwards the agent's " <>
          "lifecycle events to it. The requirement graph, the specs, the verification, and the QA " <>
          "are written once and reused by every agent, so supporting a new one is an adapter rather " <>
          "than a rewrite."
    },
    %{
      q: "Is CodeMySpec only for Claude Code?",
      a:
        "No. Claude Code is the original and deepest integration, but CodeMySpec also ships plugins " <>
          "for OpenAI Codex and Google Antigravity. The same specs, verification, and browser QA " <>
          "work regardless of which agent drives them."
    },
    %{
      q: "What is different about the early agents?",
      a:
        "Claude Code gets the full lifecycle including the five specialized subagents. On Codex, " <>
          "verification runs but its file scoping does not yet recognize Codex's edit tool, so " <>
          "change-scoped checks behave as though nothing changed. On Antigravity the five agents " <>
          "ship, but the surface emits no subagent events, so per-agent attribution does not apply " <>
          "and the test-command rewrite is delivered as a redirect instead of an edit."
    },
    %{
      q: "Which operating systems does the harness run on?",
      a:
        "The local server ships for macOS on Apple Silicon and Windows on x64. There is no Linux " <>
          "binary in the packaged install path today."
    },
    %{
      q: "Does using a plugin lock me into that agent?",
      a:
        "No. Your specs are markdown and your tests are standard ExUnit in your own repository, and " <>
          "the harness is a local server rather than part of the agent. Switching agents means " <>
          "installing a different adapter; every artifact comes with you."
    }
  ]

  def agents(conn, _params) do
    base_url = CodeMySpecWeb.Endpoint.url()
    canonical = "#{base_url}/agents"

    meta = %{
      page_title: "AI Coding Agents CodeMySpec Works With — Claude Code, Codex, Antigravity",
      meta_description:
        "CodeMySpec runs as a plugin inside Claude Code, OpenAI Codex, or Google Antigravity. " <>
          "The harness is a local server and each plugin is a thin adapter, so it is agent-agnostic " <>
          "by architecture.",
      og_title: "Works with the agent you already use",
      og_description:
        "Claude Code, OpenAI Codex, or Google Antigravity. One local harness, thin adapters, your " <>
          "own keys — so your specs and tests never depend on which agent wrote them."
    }

    json_ld_list =
      Enum.map(
        [
          %{
            "@context" => "https://schema.org",
            "@type" => "BreadcrumbList",
            "itemListElement" => [
              %{"@type" => "ListItem", "position" => 1, "name" => "Home", "item" => base_url},
              %{
                "@type" => "ListItem",
                "position" => 2,
                "name" => "Product",
                "item" => "#{base_url}/product"
              },
              %{
                "@type" => "ListItem",
                "position" => 3,
                "name" => "Supported agents",
                "item" => canonical
              }
            ]
          },
          %{
            "@context" => "https://schema.org",
            "@type" => "FAQPage",
            "mainEntity" =>
              Enum.map(@agent_faqs, fn faq ->
                %{
                  "@type" => "Question",
                  "name" => faq.q,
                  "acceptedAnswer" => %{"@type" => "Answer", "text" => faq.a}
                }
              end)
          }
        ],
        &Jason.encode!/1
      )

    render(conn, :agents,
      page_title: meta.page_title,
      meta_description: meta.meta_description,
      og_title: meta.og_title,
      og_description: meta.og_description,
      og_image: CodeMySpecWeb.ImageUrl.image_url("og-agents.png", base_url),
      canonical_url: canonical,
      json_ld_list: json_ld_list,
      faqs: @agent_faqs
    )
  end

  # /developers is the engineer-persona lander; /product is the product-scoped
  # cornerstone. The legacy plural namespace dates from when MarketMySpec lived
  # here too, so it points at the cornerstone now, not the persona page.
  def code_my_spec(conn, _params) do
    conn
    |> Plug.Conn.put_status(:moved_permanently)
    |> Phoenix.Controller.redirect(to: "/product")
  end

  def market_my_spec_redirect(conn, _params) do
    conn
    |> Plug.Conn.put_status(:moved_permanently)
    |> Phoenix.Controller.redirect(external: "https://marketmyspec.com")
  end
end
