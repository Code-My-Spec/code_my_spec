%{
  metadata: %{
    meta_title: "Marketing isn't a content problem. It's a system problem.",
    meta_description:
      "An engineer's six-week rebuild of marketing as an engineering problem. Strategy, daily plan, cadence, measurement, running on rails through Claude Code and a few MCP servers.",
    og_title: "Marketing isn't a content problem. It's a system problem.",
    og_description:
      "An engineer's six-week rebuild of marketing as an engineering problem. Running on rails through Claude Code and a few MCP servers.",
    author: "John Davenport",
    tags: [
      "marketing",
      "mcp",
      "claude-code",
      "reddit",
      "ga4",
      "search-console",
      "seo",
      "founder-marketing",
      "agentic-workflow"
    ]
  },
  hero: %{
    eyebrow_idx: "/blog · 04.28.2026",
    eyebrow_kind: "methodology",
    title_lines: ["Marketing isn't", "a content problem.", "It's a system problem."],
    title_accent_index: 2,
    deck:
      "An engineer's six-week rebuild of marketing as an engineering problem. Strategy, daily plan, cadence, measurement, running on rails through Claude Code and a few MCP servers. The honest version.",
    meta: [
      %{label: "30 min", suffix: "read"},
      %{label: "top of funnel", suffix: nil},
      %{label: "founder direct", suffix: nil},
      %{label: nil, suffix: "methodology · 06_messaging"}
    ],
    recursion_note:
      "This article was written using the system it describes. The marketing harness produced the strategy that led to writing this. You're reading the marketing harness marketing itself."
  },
  lede:
    "I've been building software for years and I'm terrible at marketing. Not \"humble brag\" terrible. Actually terrible. I've shipped products nobody used because I couldn't bring myself to tell anyone about them. Building is my happy place. Marketing is paralyzing.",
  intro_paragraphs: [
    "But I needed to market the harness. So I did what any engineer would do. I turned it into an engineering problem.",
    "Here's what six weeks taught me. <strong>Marketing isn't a content problem. It's a system problem.</strong> Reddit one week, X the next, half-built newsletter, occasional LinkedIn. It all adds up to busy, not effective. What I needed wasn't more tactics. It was a strategy → daily plan → cadence → measurement loop, running on rails."
  ],
  loop_diagram: %{
    fig_label: "// fig_01 · the_loop",
    fig_caption: "strategy → execute → measure → iterate",
    note: "// loop closes weekly · strategy evolves with customer signal"
  },
  origin: %{
    idx: "01",
    name: "how_did_i_start",
    title: "How I got into AI-powered marketing as a developer",
    paragraphs: [
      "I sat down with Claude and came up with a strategy based on some theories I had. My users hang out on Reddit. I had a few subs in mind where my experience was relevant. So we started there.",
      "First thing: hook up a Reddit MCP server. Now Claude can scan subreddits and pull thread details. We started commenting, being helpful in threads where my experience was relevant. No grand plan. Just show up and be useful.",
      "After a couple weeks, I wanted to know if any of this was working. So I added a Google Analytics MCP server. Now I could pull traffic reports right from Claude Code. And I could see it. People were actually clicking through from my comments.",
      "Then something interesting happened. I saw people signing up. Not a flood, but real registrations. So I added Google Analytics admin capabilities and set up conversion tracking so I could see the full funnel.",
      "I started researching the people who signed up. Who were they? Where did they come from? Which comments drove them?",
      "Then I wanted to make sure I was set up for SEO, because the Reddit comments were driving traffic but I had basically zero organic search presence. Added the Google Search Console MCP. Immediately found that Google thought my canonical URL was an old ngrok tunnel from development. Fixed it the same day."
    ],
    pullquote: %{
      lead: "The pattern is always the same.",
      accent: "Strategize. Add a tool. Execute. Review. Adjust.",
      tail: "Each cycle makes the next one better.",
      cite: "// I didn't plan a stack. I added each piece when I needed it."
    }
  },
  daily_loop: %{
    idx: "02",
    name: "the_daily_loop",
    title: "What the daily loop actually looks like",
    intro:
      "I tell Claude to scan Reddit. It uses a Reddit MCP server to pull hot and new posts from the subs where my audience hangs out: r/ChatGPTCoding, r/vibecoding, r/ClaudeAI, founder communities. It writes lead files: little markdown docs with the thread title, score, top comment vibe, and an angle for why my experience is relevant. I pick 2-3 threads.",
    steps: [
      %{
        n: "01",
        of: "scan",
        actor: "claude",
        title: "Pull hot + new posts. Write lead files.",
        body:
          "Reddit MCP fetches threads from target subs. Each lead is a markdown file with title, score, top comment sentiment, and an angle on why I should care. I read them. I pick 2-3."
      },
      %{
        n: "02",
        of: "draft",
        actor: "claude",
        title: "Talking points, not a comment.",
        body:
          "Claude gives me the angle and the key insight to hit, not a ready-to-post comment. AI-written comments read like AI-written comments and Reddit can tell."
      },
      %{
        n: "03",
        of: "voice",
        actor: "me",
        title: "I dictate. Claude polishes.",
        body:
          "Natural cadence, tangents, genuine reactions. That's the part that sounds human because it is human. Claude does a light pass on phrasing. I post it."
      },
      %{
        n: "04",
        of: "measure",
        actor: "claude",
        title: "GA4 + Search Console pull.",
        body:
          "Every link carries a UTM tag, so I can see exactly which comment drove which sessions. Search Console tells me what's getting indexed and what queries are surfacing."
      },
      %{
        n: "05",
        of: "adjust",
        actor: "me",
        title: "Tomorrow uses today's signal.",
        body:
          "Threads that drove depth get more weight. Comment shapes that bombed get retired. The strategy file evolves. Then I scan again."
      }
    ],
    outro: "I run the loop daily. About 30 minutes. Some days less."
  },
  stack: %{
    idx: "03",
    name: "the_stack",
    title: "Which MCP servers make up the marketing stack",
    intro: "Three servers, each doing one thing. Plus one SEO plugin that earned its keep on day one.",
    mcps: [
      %{
        role: "// reddit",
        name: "Reddit MCP",
        pill: "workhorse",
        desc:
          "Browse subreddits. Get post details with comments. Search. The workhorse. Lets me read the room before I say anything.",
        repo: "reddit-mcp-buddy"
      },
      %{
        role: "// analytics",
        name: "GA4 MCP",
        pill: "measure",
        desc:
          "Traffic reports filtered by UTM campaign. Which threads drove traffic. How long people stayed. How many pages they viewed.",
        repo: "analytics-mcp"
      },
      %{
        role: "// search_console",
        name: "GSC MCP",
        pill: "seo",
        desc:
          "Indexing status. Query impressions. Canonical issues. Found out Google thought my canonical URL was an old ngrok tunnel. Would never have caught that without it.",
        repo: "mcp-gsc"
      }
    ],
    seo_section: %{
      sub: "// the seo plugin that changed the game",
      paragraphs: [
        "The <strong>Claude SEO plugin</strong> changed the game for me. It's a full SEO audit and optimization skill. Runs parallel subagents for technical SEO, content quality, schema markup, sitemaps, performance, and AI search readiness.",
        "I ran <code>/seo audit</code> on my site. Scored 56/100. Found my canonical URLs were doubling, my schema JSON-LD had broken URLs, and Cloudflare was blocking every AI crawler. Fixed all of it the same day. It also handles PageSpeed, CrUX field data, and URL indexing submissions. I submitted 23 URLs for indexing through it in one session.",
        "I encoded the repeatable workflows as slash commands: <code>/scan-reddit</code>, <code>/draft-response</code>, <code>/news-scan</code>, <code>/seo audit</code>. Each one reads my memory files first so Claude has context about my positioning before it starts."
      ]
    }
  },
  mistakes: %{
    idx: "04",
    name: "failure_modes",
    title: "The biggest mistakes to avoid",
    items: [
      %{
        label: "failure_01",
        title: "AI-drafted comments bomb.",
        body:
          "Reddit can tell. The comments that perform are the ones I dictate and Claude polishes. Natural cadence, tangents, genuine reactions. That's what makes it human."
      },
      %{
        label: "failure_02",
        title: "Homepage links die.",
        body:
          "Links to specific content work. Links to homepage don't. My best comment linked to one article. Drove sessions for weeks. Worst posts were homepage links: 4 second average duration, 75% bounce."
      },
      %{
        label: "failure_03",
        title: "Earnest pitches into dismissive rooms.",
        body:
          "The scan captures top comments and sentiment. If the top comment is dismissive, walking in earnest gets destroyed. The top comment tells you what the audience rewards."
      },
      %{
        label: "failure_04",
        title: "The content has to exist first.",
        body:
          "You can't link to something you haven't written. I have 100+ articles in my library. When a thread asks about testing AI-generated code, I have an article. The marketing works because the content is genuinely useful."
      }
    ],
    bonus: %{
      sub: "// let reddit threads tell you what to write",
      body:
        "My best-performing content series came from reading r/vibecoding threads. Someone posted a list of 15 tools vibe coders should use. The top comment: \"Too many words, just prompt.\" The second: \"I have no idea what any of that means.\" So I wrote a series explaining those fundamentals in plain English. The articles get linked in threads asking the exact questions they answer. The content writes itself when you listen to what people are confused about."
    }
  },
  results: %{
    idx: "05",
    name: "results",
    title: "What the numbers actually look like",
    intro: "Six weeks of running the loop. Pulled from GA4 and Search Console MCP tools.",
    snapshot: %{
      head_left: "// snapshot · t+6w",
      head_right: "source · ga4 + gsc",
      stats: [
        %{value: "80", unit: "users", label: "// peak day", ctx: "Two consecutive all-time records in one week. 61 → 80."},
        %{value: "107", unit: "sessions", label: "// reddit utm · 3d", ctx: "Average 4:25 per session. People are reading entire articles."},
        %{value: "30", unit: "users", label: "// registered", ctx: "7 signups in last 7 days. Pace tripled month-over-month."},
        %{value: "9/10", unit: nil, label: "// reg page source", ctx: "Of people who hit registration, came from Reddit comments."},
        %{value: "17", unit: "min", label: "// deepest cohort", ctx: "Empathy reply on a \"month 3 wall\" thread. 13.8 pages avg."},
        %{value: "87", unit: "↑", label: "// top comment", ctx: "No link. Reputation comment. Compounds quietly."}
      ]
    },
    findings_sub: "// what the funnel taught me",
    findings: [
      %{
        label: "finding_01",
        lead: "High upvotes don't always mean high click-through.",
        body: "Thread size and comment position matter more than upvote count."
      },
      %{
        label: "finding_02",
        lead: "Empathy comments produce depth.",
        body:
          "A reply on a \"month 3 wall\" frustration thread drove only 12 sessions, but those users averaged 17 minutes and 13.8 pages each."
      },
      %{
        label: "finding_03",
        lead: "Tool comparison comments produce volume.",
        body: "Best-by-volume comment drove 67 sessions from 42 users. Different shape, different goal."
      },
      %{
        label: "finding_04",
        lead: "Reputation comments don't drive traffic.",
        body: "My highest-upvoted comment had no link. That's fine. Reputation compounds."
      }
    ],
    closer:
      "Is this going to make me rich? Not yet. Can a solo founder run this in 30 minutes a day and see real, measurable traction? Yeah."
  },
  files_section: %{
    idx: "06",
    name: "why_files",
    title: "Why storing everything as files makes the system work",
    paragraphs: [
      "The leads, the touchpoints, the content, the strategy docs, the analytics baselines: it's all git-tracked markdown. When I scan Reddit next week, Claude reads the touchpoints and knows what I've already said, which threads I've engaged, and what angles worked. The system remembers what I forget.",
      "Marketing advice for founders usually falls into \"just put yourself out there\" (useless) or \"hire a marketer\" (expensive). What actually works is treating it like engineering. Define inputs. Build a process. Create feedback loops. Iterate on data. You don't need a marketing degree. You need Claude Code, a few MCP servers, and the willingness to show up where your users talk."
    ]
  },
  cta: %{
    eyebrow: "// next_step",
    title: "Run /marketing-strategy.",
    body: "30 minutes. A real strategy. A daily plan you'll actually follow. Free during early access.",
    primary: %{
      label: "▸ Run /marketing-strategy",
      href:
        "/products/market-my-spec?utm_source=blog&utm_medium=internal&utm_campaign=agentic-marketing-with-mcp"
    },
    secondary: %{label: "▸ Read the methodology", href: "/methodology"}
  },
  faq: %{
    idx: "07",
    name: "faq",
    title: "Frequently asked questions",
    items: [
      %{
        question: "Do I have to build all this myself?",
        answer:
          "No. The MarketMySpec plugin packages the loop. <code>/marketing-strategy</code> runs the strategy interview. <code>/daily-plan</code> tells you what to work on today. <code>/marketing-stack</code> installs the MCP recipes your strategy needs. Free during early access. BYOK."
      },
      %{
        question: "Can a founder with no marketing experience use this?",
        answer:
          "Yes. The entire approach is built around engineering principles: define inputs, build a repeatable process, create feedback loops, iterate on data. You don't need marketing expertise. You need the willingness to show up where your users are and let the data guide your next move."
      },
      %{
        question: "How much time does this loop take per day?",
        answer:
          "About 30 minutes once the MCP servers are configured and the slash commands are set up. The scanning, drafting, and analytics review are fast because Claude handles the data gathering. The human time goes into picking threads, dictating authentic responses, and reviewing analytics."
      },
      %{
        question: "Why not let AI write the full Reddit comment?",
        answer:
          "Reddit communities can detect AI-written comments quickly, and those comments perform poorly. The comments that drive real engagement are ones where you dictate your genuine thoughts and let Claude polish the phrasing. The natural cadence, tangents, and authentic reactions are what make a comment resonate."
      },
      %{
        question: "Do I need a large content library before starting?",
        answer:
          "Not to start, but the approach works best when you have content to link to. You can begin by being helpful in discussions without linking anything. As you spot content gaps from real conversations, write articles to fill those gaps. Over time, your library grows organically based on actual demand."
      },
      %{
        question: "Which MCP servers are essential to get started?",
        answer:
          "Start with just the Reddit MCP server and Google Analytics MCP server. Reddit lets you find and engage with your audience. Analytics lets you see what is working. Add Search Console and the SEO plugin once your content is shipping consistently. Or install MarketMySpec and let <code>/marketing-stack</code> do it for you."
      },
      %{
        question: "How do you track which comments lead to signups?",
        answer:
          "Every link carries UTM parameters: source, medium, campaign, and content. The content tag is unique per comment, so I can trace a signup back through the funnel. The data showed me that empathy comments in frustration threads produce the deepest readers, while tool comparison comments produce the most volume. Different strategies for different goals."
      }
    ]
  },
  sources: %{
    idx: "08",
    name: "sources",
    title: "Sources",
    items: [
      %{
        title: "RSL/A: Claude Code Marketing Agency Workflow",
        note: "2-person agency · 9 MCP tools · 3-5x productivity"
      },
      %{
        title: "FutureSearch: Marketing Pipeline Using Claude Code",
        note: "Automated community scanning · 2-3% signal rate"
      },
      %{
        title: "MKT1: Marketers Building with Claude Code",
        note: "Positioning checker · lookalike agents · ad intelligence"
      },
      %{
        title: "Creating AI Agents for Solopreneur Marketing",
        note: "7 agent categories · minimal stack"
      }
    ]
  },
  footer_closing:
    "This is how I market the harness. It's a feedback loop, codified as MCP tools and slash commands. If you're a founder struggling with marketing, skip the guru advice. Build the loop. Or install the one I built."
}
