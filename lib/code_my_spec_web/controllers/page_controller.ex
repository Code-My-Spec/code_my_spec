defmodule CodeMySpecWeb.PageController do
  use CodeMySpecWeb, :controller

  alias CodeMySpec.Intake
  alias CodeMySpecWeb.Plugs.IntakeSession

  @doc """
  Starts a plan from the home page and hands the visitor to the conversation.

  The description is the one thing a visitor can give before they have been
  asked anything, so it is what the home page collects. Recording it here
  rather than passing it as a query parameter means the first thing they typed
  survives a bookmark, a refresh, or a closed tab — the plan is already a row
  by the time /build renders.

  An empty box is not an error worth a page: it just means they pressed the
  button with nothing to say, so send them to the same place and let the
  conversation ask.
  """
  def start_build(conn, params) do
    description = params |> Map.get("description", "") |> String.trim()

    with token when is_binary(token) <- get_session(conn, IntakeSession.session_key()),
         {:ok, plan} <- Intake.start_plan(token),
         true <- description != "",
         {:ok, _plan} <- Intake.describe(plan, description) do
      redirect(conn, to: ~p"/build")
    else
      _ -> redirect(conn, to: ~p"/build")
    end
  end

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
                    "You keep everything. It's a standard Phoenix app on your disk that compiles, tests, and ships without us. Your specifications are executable Elixir test files in your repo, so they keep running without us too. No lock-in."
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
        "CodeMySpec lets you build a reliable, maintainable application without writing code and without " <>
          "prompting the model. You work through a process instead: it interviews you about what you " <>
          "want, writes down the behavior you agree on, turns that into tests that check your app the " <>
          "way a person would, and builds until those tests hold. You don't supervise it — the harness " <>
          "supervises it."
    },
    %{
      q: "What makes CodeMySpec's specifications different?",
      a:
        "They execute. CodeMySpec converts a story's acceptance criteria into named rules, Gherkin " <>
          "scenarios, and executable specifications that run against your code, so the behavior you " <>
          "agreed on is continuously checked against what the agent actually built. A written " <>
          "specification is a claim about intent; an executable one is a claim that gets checked. If " <>
          "your application is the castle, these are the walls."
    },
    %{
      q: "Do I have to write markdown specification documents?",
      a:
        "No. The written module specification is a configuration knob you can turn off, and plenty of " <>
          "projects run without it because generating prose documents costs tokens and time. The " <>
          "executable specifications are the part that is not optional, because they are the layer that " <>
          "verifies itself."
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
      q: "Does CodeMySpec only work with one kind of app?",
      a:
        "No. The core lifecycle — planning the work, agreeing the behavior, writing the tests, and QAing " <>
          "the running app — works on any technology through your AI agent. It goes deepest on the " <>
          "stack it was built for, where it understands sixteen kinds of building block and the rules " <>
          "each one follows."
    },
    %{
      q: "Does CodeMySpec lock me in?",
      a:
        "No. Your executable specifications and your tests are ordinary test files in your own " <>
          "repository, and you bring your own model and API keys with no markup on tokens. There is no " <>
          "proprietary spec format and nothing to export. If you stopped using CodeMySpec tomorrow, you " <>
          "would keep every artifact of value, and the specifications would still run."
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
        "Every time the agent stops, the work is built and run through every check and test before it is " <>
          "allowed to continue, and a failure can stop it there. How strict each check is, is up to " <>
          "you. The point is that the agent cannot quietly leave things broken or skip the tests and " <>
          "tell you it was fine."
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
        "Anyone who needs the software to still work next month. That includes people who are not " <>
          "engineers: if you have built something with AI and watched it break every time you change " <>
          "it, this is the layer that was missing. It is not for throwaway prototypes. If you are " <>
          "throwing it away, prompt directly; if you are shipping it, you need the harness."
    }
  ]

  def product(conn, _params) do
    base_url = CodeMySpecWeb.Endpoint.url()
    canonical = "#{base_url}/product"

    meta = %{
      page_title: "CodeMySpec — Build Software With AI That Doesn't Fall Down",
      meta_description:
        "Build a reliable, maintainable application without writing code and without prompting the " <>
          "model. You work through a process; CodeMySpec holds the machine to it, and proves the " <>
          "result with tests that use your app like a person. Free to build.",
      og_title: "AI built it in an hour. Now make it hold.",
      og_description:
        "No code, no prompting. Five steps, and only two are yours: say what you want, and say whether " <>
          "it came out right. The harness does the rest and proves it works."
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
              "Executable specifications: acceptance criteria compiled into named rules, Gherkin " <>
                "scenarios and runnable spec files that continuously verify intent against the code; " <>
                "requirement graph that sequences the work; 16 Phoenix component types; " <>
                "dependency-graph validation and architecture enforcement; automatic compile, Credo, " <>
                "test and Spex verification on every agent stop; agentic browser QA against the " <>
                "running app; plugins for Claude Code, OpenAI Codex and Google Antigravity; specs and " <>
                "tests as real Elixir test files in your own repository; bring your own model and " <>
                "keys with no token markup",
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
          CodeMySpecWeb.MarketingComponents.faq_json_ld(@product_faqs)
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
        "No. Your executable specifications and tests are real Elixir test files in your own " <>
          "repository, and the harness is a local server rather than part of the agent. Switching " <>
          "agents means installing a different adapter; every artifact comes with you and still runs."
    }
  ]

  # Claims verified against source 2026-07-26: `argument-hint: "[architecture|ui|
  # strategy]"` in the design skill, output at `.code_my_spec/design/
  # design_system.html` via the daisyUI CDN, and DesignUi appears in zero graph
  # templates — so this step is genuinely optional and the page must not imply
  # otherwise. The limits below are the differentiator, not a liability:
  # everyone in this category overstates and the buyer has already been burned.
  @design_faqs [
    %{
      q: "Do I need to know design, or write any CSS?",
      a:
        "No. The step interviews you and offers concrete options for every question, so you are " <>
          "picking rather than describing. You never open a design tool and you never write a line of " <>
          "styling."
    },
    %{
      q: "What do I actually end up with?",
      a:
        "One page in your own project that documents your choices and renders them live at the same " <>
          "time, in your colors and your type, with a switch for light and dark. It is plain HTML you " <>
          "can open in a browser, read, edit, and take anywhere. Because the documentation and the " <>
          "preview are the same file, they cannot drift apart."
    },
    %{
      q: "Does this stop the AI from ignoring my design system?",
      a:
        "It makes ignoring it much harder, and it is worth being precise about how. Your design " <>
          "system is handed to the agent as something it must read before building, and every page " <>
          "has to state its design choices before any code exists. What does not happen is a machine " <>
          "rendering your finished page and comparing it to your design system pixel by pixel. No " <>
          "tool does that today, and anyone implying otherwise is overstating. Reviewing pages is " <>
          "still yours, with far less to review because the decisions are already made."
    },
    %{
      q: "Can I change my mind later?",
      a:
        "Yes. Run the step again on an existing project and it walks you through revisions instead " <>
          "of starting over. The file updates as you answer, so you can see your palette and type " <>
          "while changing your mind is still cheap."
    },
    %{
      q: "Do I have to do this before I build anything?",
      a:
        "No, nothing blocks you from building without it. But run it before your first page and " <>
          "every page after inherits the decision. Run it late and you will be revisiting pages that " <>
          "guessed."
    },
    %{
      q: "Will my site still look like every other AI-built site?",
      a:
        "That sameness comes from nothing having told the model how your project should look, so it " <>
          "used the average of everything it trained on. Once your choices are written down and every " <>
          "page has to reference them, the average stops being the default. The decision is the fix, " <>
          "and the point of this step is that you make it once instead of arguing about colors on " <>
          "every page."
    }
  ]

  # Promoted from `/landing/vibe-coding-rebuild` content on 2026-07-26. It is a
  # service offer with pricing and a booking CTA, not an essay, so it wanted
  # components and FAQPage schema that markdown cannot produce. Copy is carried
  # over intact; only the FAQ presentation changed.
  @rebuild_faqs [
    %{
      q: "Why trust this over an agency?",
      a:
        "Look at how cleanup agencies describe the work: audit, refactor, contact us for a quote. " <>
          "The deliverable is cleaner code, which you cannot evaluate, on a timeline you cannot " <>
          "verify. This process produces its proof as it goes: the stories and specs land in your " <>
          "hands early, in plain language, and you check them against your own business before the " <>
          "rebuild starts. I have not found a cleanup service that hands you the specification as an " <>
          "artifact you keep. Here it is the point."
    },
    %{
      q: "What do you need from me?",
      a:
        "Access to the running app and the code export, plus a few conversations. You are the " <>
          "oracle for step one: only you know which behaviors are features and which are bugs you " <>
          "have been living with."
    },
    %{
      q: "Can my current app keep running during the rebuild?",
      a:
        "Yes. Nothing in the process modifies your app or its code. The specs drive it through the " <>
          "browser the way a user would, against a test account or a staging copy. You switch over " <>
          "when the new app passes."
    },
    %{
      q: "What if I only want the specs?",
      a:
        "That is a valid stopping point. The stories and specs are written against your business, " <>
          "not my stack. Take them anywhere."
    },
    %{
      q: "Doesn't \"never rewrite from scratch\" apply here?",
      a:
        "The famous warning is about losing accumulated knowledge: years of edge cases and bug fixes " <>
          "encoded in old code nobody remembers. The warning is correct, and this process is built " <>
          "around it. The first three steps capture that knowledge in executable form before a single " <>
          "line gets rebuilt. A rewrite without specs is a gamble; a rewrite against specs extracted " <>
          "from the running system is a migration with a checklist. The warning also assumes " <>
          "battle-tested code carrying years of fixes. A vibe coded app is months old and carries the " <>
          "opposite: generated bulk nobody ever reviewed."
    }
  ]

  def vibe_coding_rebuild(conn, _params) do
    base_url = CodeMySpecWeb.Endpoint.url()
    canonical = "#{base_url}/vibe-coding-rebuild"

    meta = %{
      page_title: "Vibe Coding Rebuild & Cleanup Service | CodeMySpec",
      meta_description:
        "Your Lovable or Replit app broke under real use. We reverse-engineer it into written " <>
          "specs, then rebuild it on a stack you own. Quoted straight, from $500.",
      og_title: "Vibe Coding Rebuild: Keep the Behavior, Lose the Slop",
      og_description:
        "The app that broke is still a working specification of your business. We extract the " <>
          "stories, pin the behavior in executable specs, and rebuild on a stack you own."
    }

    json_ld_list =
      Enum.map(
        [
          %{
            "@context" => "https://schema.org",
            "@type" => "Service",
            "@id" => "#{canonical}#service",
            "name" => "Vibe Coding Rebuild",
            "url" => canonical,
            "serviceType" => "Software rebuild and specification recovery",
            "description" => meta.meta_description,
            "provider" => %{"@id" => "#{base_url}/#organization"},
            "offers" => %{
              "@type" => "Offer",
              "price" => "500",
              "priceCurrency" => "USD",
              "description" => "Quoted per engagement, $500 minimum"
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
                "name" => "Vibe coding rebuild",
                "item" => canonical
              }
            ]
          },
          CodeMySpecWeb.MarketingComponents.faq_json_ld(@rebuild_faqs)
        ],
        &Jason.encode!/1
      )

    render(conn, :vibe_coding_rebuild,
      page_title: meta.page_title,
      meta_description: meta.meta_description,
      og_title: meta.og_title,
      og_description: meta.og_description,
      og_image:
        CodeMySpecWeb.ImageUrl.image_url("og-landing-vibe-coding-rebuild.png", base_url),
      canonical_url: canonical,
      json_ld_list: json_ld_list,
      faqs: @rebuild_faqs
    )
  end

  # The sibling of @design_faqs. Same shape of worry, other axis: "how do I stop
  # it breaking" rather than "how do I stop it looking generic".
  @behavior_faqs [
    %{
      q: "Do I have to write any of this in code?",
      a:
        "No. You describe what the software should do in ordinary sentences, and you agree the " <>
          "rules in a conversation. Turning those into something that runs is the machine's job, " <>
          "not yours."
    },
    %{
      q: "What actually stops the AI changing something I did not ask it to?",
      a:
        "Every rule you agreed becomes a check that runs on every change. If a change breaks one " <>
          "of them, it shows up immediately rather than three weeks later when a customer finds it."
    },
    %{
      q: "How is this different from the tests a developer would write?",
      a:
        "Tests are written after the fact, by whoever wrote the code, in the language of the code. " <>
          "These are written before it, in your words, from the conversation about what the software " <>
          "should do. You can read every one of them without knowing anything technical."
    },
    %{
      q: "What happens when I change my mind about a rule?",
      a:
        "You change the rule, and the check changes with it. Deciding once does not mean deciding " <>
          "forever — it means nothing gets to change quietly, without you."
    },
    %{
      q: "Does this slow me down?",
      a:
        "It moves the work earlier. The conversation takes an afternoon; finding out in production " <>
          "that a feature you shipped last month stopped working takes considerably longer."
    }
  ]

  def design_system(conn, _params) do
    base_url = CodeMySpecWeb.Endpoint.url()
    canonical = "#{base_url}/design-system"

    meta = %{
      page_title: "Design System: Decide How It Looks Once | CodeMySpec",
      meta_description:
        "Answer five questions about how your project should look. Every page built after that " <>
          "references your answers instead of inventing its own. No design tools, no CSS.",
      og_title: "Decide how it looks once",
      og_description:
        "Vibe coded projects look alike because nothing told the model how yours should look. Five " <>
          "questions, one afternoon, and a design system every page after that has to follow."
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
                "name" => "Design system",
                "item" => canonical
              }
            ]
          },
          CodeMySpecWeb.MarketingComponents.faq_json_ld(@design_faqs)
        ],
        &Jason.encode!/1
      )

    render(conn, :design_system,
      page_title: meta.page_title,
      meta_description: meta.meta_description,
      og_title: meta.og_title,
      og_description: meta.og_description,
      og_image: CodeMySpecWeb.ImageUrl.image_url("og-design-system.png", base_url),
      canonical_url: canonical,
      json_ld_list: json_ld_list,
      faqs: @design_faqs
    )
  end

  def behavior(conn, _params) do
    base_url = CodeMySpecWeb.Endpoint.url()
    canonical = "#{base_url}/behavior"

    meta = %{
      page_title: "Decide What It Does Once | CodeMySpec",
      meta_description:
        "AI-built apps break because nobody wrote down what they were supposed to do. Describe the " <>
          "behavior once, in your own words, and every change after that gets checked against it.",
      og_title: "Decide what it does once",
      og_description:
        "Your app keeps breaking because nothing wrote down what it was supposed to do. Agree the " <>
          "rules in plain English, and every change after that has to keep them true."
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
              %{"@type" => "ListItem", "position" => 3, "name" => "Behavior", "item" => canonical}
            ]
          },
          CodeMySpecWeb.MarketingComponents.faq_json_ld(@behavior_faqs)
        ],
        &Jason.encode!/1
      )

    render(conn, :behavior,
      page_title: meta.page_title,
      meta_description: meta.meta_description,
      og_title: meta.og_title,
      og_description: meta.og_description,
      og_image: CodeMySpecWeb.ImageUrl.image_url("og-behavior.png", base_url),
      canonical_url: canonical,
      json_ld_list: json_ld_list,
      faqs: @behavior_faqs
    )
  end

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
          CodeMySpecWeb.MarketingComponents.faq_json_ld(@agent_faqs)
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
