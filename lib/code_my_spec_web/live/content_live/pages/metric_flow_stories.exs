[
  %{
    status: nil,
    description: "As a direct user (not under an agency), I want to subscribe to a flat monthly plan so that I can unlock AI features (Correlations, Intelligence, Visualizations). Payments flow to the default platform Stripe account.",
    title: "Direct User Subscription: Flat Monthly Plan via Platform Stripe",
    tags: [],
    criteria: [
      %{
        description: "On successful payment, the user's account is updated to `subscribed: true` and the Stripe `customer_id` and `subscription_id` are stored",
        verified: false
      },
      %{
        description: "Checkout uses Stripe Checkout Session or Payment Element and redirects to a success/cancel URL",
        verified: false
      },
      %{
        description: "Direct (non-agency) users can initiate checkout from the paywall modal or from account settings",
        verified: false
      },
      %{
        description: "A subscription plan record exists in the system with a name, monthly price, and Stripe Price ID",
        verified: false
      },
      %{
        description: "Users can cancel their subscription from account settings, which triggers a cancel-at-period-end via the Stripe API",
        verified: false
      },
      %{
        description: "Users can view their current plan and billing status in account settings",
        verified: false
      },
      %{
        description: "Subscription cancellations are handled gracefully: the user retains access until the end of the current billing period, then is downgraded to free",
        verified: false
      },
      %{
        description: "A Stripe webhook handler processes `customer.subscription.created`, `customer.subscription.updated`, and `customer.subscription.deleted` events to keep local subscription state in sync",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As the platform, I need a robust Stripe webhook handler that processes subscription lifecycle events for both direct users (platform account) and agency customers (connected accounts) so that subscription state stays accurate in real time.",
    title: "Stripe Webhook Handler: Subscription Lifecycle Sync",
    tags: [],
    criteria: [
      %{
        description: "On `payment_failed`, the user's subscription is marked `past_due` and they receive an email prompting them to update their payment method",
        verified: false
      },
      %{
        description: "A Stripe webhook endpoint exists at a well-known URL and is registered in both the platform Stripe account and any agency connected accounts",
        verified: false
      },
      %{
        description: "The handler verifies the `Stripe-Signature` header using the appropriate webhook secret (platform secret for direct users, agency-specific secret for agency customers)",
        verified: false
      },
      %{
        description: "The handler processes at minimum: `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`, `invoice.payment_succeeded`, `invoice.payment_failed`",
        verified: false
      },
      %{
        description: "Webhook processing failures are captured and surfaced in an internal error log; Stripe retries are handled gracefully",
        verified: false
      },
      %{
        description: "All webhook events are logged with their Stripe event ID, type, processed status, and timestamp for auditability",
        verified: false
      },
      %{
        description: "Webhook events are idempotent — duplicate deliveries do not double-process state changes",
        verified: false
      },
      %{
        description: "On `subscription.deleted`, the user is downgraded to free at the end of the billing period",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As an agency admin, I want to create and manage subscription plans for my customers with my own pricing so that I have full control over what I charge for access to MetricFlow under my agency.",
    title: "Agency Plan Management: Create Custom Subscription Plans",
    tags: [],
    criteria: [
      %{
        description: "When creating a plan, the platform creates a corresponding Stripe Product and Price on the agency's connected Stripe account (using the agency's `stripe_account_id`)",
        verified: false
      },
      %{
        description: "Agency admins can define one or more subscription plans within their agency, specifying a name and monthly price",
        verified: false
      },
      %{
        description: "The agency settings UI lists all active plans with their Stripe Price IDs and status",
        verified: false
      },
      %{
        description: "Agency plans are scoped to the agency and not visible to other agencies or direct users",
        verified: false
      },
      %{
        description: "Agency admins can deactivate a plan; existing subscribers remain on the plan until they cancel or are migrated",
        verified: false
      },
      %{
        description: "Agency admins can update plan pricing; the platform creates a new Stripe Price and marks the old one as inactive",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As an agency admin, I want to connect my own Stripe account to the platform so that subscription payments from my customers flow directly into my Stripe account, not the platform's default account.",
    title: "Agency Stripe Connect: Onboard Agency's Own Stripe Account",
    tags: [],
    criteria: [
      %{
        description: "If the agency abandons onboarding, their account is marked `stripe_connected: false` and they can retry",
        verified: false
      },
      %{
        description: "On completion, the platform stores the agency's `stripe_account_id` and marks the agency as `stripe_connected: true`",
        verified: false
      },
      %{
        description: "The platform initiates a Stripe Connect OAuth flow (Standard or Express account) and redirects the agency to Stripe's onboarding UI",
        verified: false
      },
      %{
        description: "An agency admin can navigate to a Billing or Settings page and initiate Stripe Connect onboarding",
        verified: false
      },
      %{
        description: "Agency Stripe connection state is stored on the `Agency` schema with `stripe_account_id`, `stripe_connect_status`, and `stripe_onboarded_at` fields",
        verified: false
      },
      %{
        description: "If an agency is not Stripe-connected, their customers cannot be billed through the agency and are prompted to use the platform's default billing instead",
        verified: false
      },
      %{
        description: "An agency can disconnect their Stripe account; disconnection is reflected immediately and existing customer subscriptions are flagged for review",
        verified: false
      },
      %{
        description: "The agency dashboard shows Stripe connection status (connected / not connected / restricted)",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a user who signed up under an agency, I want to subscribe to the agency's plan so that my payment goes directly to my agency, and I gain access to AI features under their account.",
    title: "Agency Customer Billing: Route Subscription Payments to Agency Stripe Account",
    tags: [],
    criteria: [
      %{
        description: "Agency customer subscription status is synced via webhooks just like direct users: `subscribed`, `past_due`, `canceled`",
        verified: false
      },
      %{
        description: "A user's billing context (agency vs. direct) is immutable after subscription creation — changing it requires canceling and re-subscribing",
        verified: false
      },
      %{
        description: "If the agency's Stripe account becomes disconnected after a customer subscribes, the customer's subscription state is preserved but flagged; billing for new customers through the agency is paused",
        verified: false
      },
      %{
        description: "Webhook events for agency customer subscriptions are routed and processed correctly using the agency's `stripe_account_id` to identify the source",
        verified: false
      },
      %{
        description: "On successful payment, the customer's `subscription_id`, `stripe_customer_id`, and `agency_id` are stored; the subscription is recorded as belonging to the agency's Stripe account",
        verified: false
      },
      %{
        description: "Checkout for agency customers uses Stripe Checkout or Payment Element pointed at the agency's connected Stripe account (`stripe_account: agency.stripe_account_id`)",
        verified: false
      },
      %{
        description: "Agency customers are shown the agency's available plan(s) on the paywall and checkout screens, not the platform's default plan",
        verified: false
      },
      %{
        description: "When a user signs up via an agency invite link or referral token, they are associated with that agency (`agency_id` stored on the user record)",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a free user, I should have access to the Dashboard and Integrations pages but be blocked from AI-powered features (Correlations, Intelligence, Visualizations) with a clear upgrade prompt so I understand the value of upgrading.",
    title: "Feature Gate: Paywall AI Features for Free Users",
    tags: [],
    criteria: [
      %{
        description: "The paywall UI clearly communicates which plan unlocks AI features and the monthly price",
        verified: false
      },
      %{
        description: "A CTA on the paywall routes the user to the subscription checkout flow",
        verified: false
      },
      %{
        description: "Feature access is enforced server-side — gating cannot be bypassed by manipulating client state",
        verified: false
      },
      %{
        description: "Paid users and agency customers with active subscriptions see all features without restriction",
        verified: false
      },
      %{
        description: "Free users who navigate to Correlations, Intelligence, or Visualizations see a paywall/upgrade modal instead of the feature content",
        verified: false
      },
      %{
        description: "Free users can access the Dashboard and all Integrations pages without restriction",
        verified: false
      },
      %{
        description: "Paywalled routes return 402 or redirect with a flash message when accessed via direct URL by free users",
        verified: false
      },
      %{
        description: "A helper function or plug (e.g. `require_subscription`) is reusable across all paywalled routes",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As an agency admin, I want to see and manage all my subscribed customers in one place so that I have visibility into my revenue and can take action on individual accounts.",
    title: "Agency Admin: Customer Subscription Management Dashboard",
    tags: [],
    criteria: [
      %{
        description: "The customer list paginates and is searchable by name or email",
        verified: false
      },
      %{
        description: "Agency admins can view a list of all customers subscribed under their agency with their subscription status, plan, and subscription start date",
        verified: false
      },
      %{
        description: "Agency admins can see total active subscribers and MRR in a summary view (calculated from local data, not a live Stripe API call)",
        verified: false
      },
      %{
        description: "Agency admins can cancel a specific customer's subscription, which triggers a cancel-at-period-end via the Stripe API on the agency's connected account",
        verified: false
      },
      %{
        description: "Agency admins cannot see or modify other agencies' customer data",
        verified: false
      },
      %{
        description: "Subscription status badge reflects real-time synced state: active, past_due, canceled, trialing",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a new user, I want to register for an account so that I can access the reporting platform and manage my marketing data.",
    title: "User Registration and Account Creation",
    tags: ["mvp:v1", "epic:authentication", "priority:high"],
    criteria: [
      %{description: "Email verification is required before account activation", verified: false},
      %{
        description: "User is prompted to create an account name during registration",
        verified: false
      },
      %{
        description: "Duplicate email addresses are rejected with clear error message",
        verified: false
      },
      %{
        description: "Registration form validates email format and password strength",
        verified: false
      },
      %{
        description: "Account type is specified during registration (Client or Agency)",
        verified: false
      },
      %{
        description: "User who creates the account becomes the originator and default owner",
        verified: false
      },
      %{
        description: "After registration, user is logged in and directed to onboarding flow",
        verified: false
      },
      %{description: "User can register with email and password", verified: false}
    ]
  },
  %{
    status: nil,
    description: "As a registered user, I want to log in securely so that I can access my account and data.",
    title: "User Login and Session Management",
    tags: ["priority:high", "mvp:v1", "epic:authentication"],
    criteria: [
      %{description: "User session persists across browser tabs", verified: false},
      %{description: "User can log in with email and password", verified: false},
      %{description: "User can use Remember me option for extended sessions", verified: false},
      %{description: "Inactive sessions expire after a reasonable period", verified: false},
      %{description: "User can log out from any page", verified: false},
      %{description: "Failed login attempts show clear error messages", verified: false}
    ]
  },
  %{
    status: nil,
    description: "As an account owner, I want to invite team members (both inside and outside my organization) to my account so that multiple people can access our data with appropriate permissions.",
    title: "Multi-User Account Access",
    tags: ["mvp:v1", "epic:permissions", "priority:high"],
    criteria: [
      %{
        description: "Access levels follow hierarchy: only owners can add owners, only admins can add admins, etc.",
        verified: false
      },
      %{
        description: "All users on an account see the same data with account-level isolation",
        verified: false
      },
      %{description: "Account owner or admin can remove users from the account", verified: false},
      %{description: "Account owner or admin can modify user access levels", verified: false},
      %{
        description: "Account owner or admin can invite users to their account via email",
        verified: false
      },
      %{description: "Each user has their own login credentials", verified: false},
      %{
        description: "Users can have different access levels: owner, admin, account manager, read-only",
        verified: false
      },
      %{
        description: "Account owner can view all users in their account with their access levels",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As an account owner, I want to delete my account permanently so that I can remove all my data from the system.",
    title: "Account Deletion (Owner Only)",
    tags: ["priority:low", "epic:account-management"],
    criteria: [
      %{
        description: "Warning explains that deletion is permanent and irreversible",
        verified: false
      },
      %{description: "Delete requires password re-entry for security", verified: false},
      %{description: "Delete requires confirmation with account name typed in", verified: false},
      %{
        description: "Account originator cannot delete account they originated (only owner can)",
        verified: false
      },
      %{description: "Only account owner role can access delete account option", verified: false},
      %{description: "Admin and other roles cannot delete account", verified: false},
      %{description: "User receives confirmation email after deletion", verified: false},
      %{description: "All user access grants to this account are revoked", verified: false},
      %{
        description: "Upon deletion, all account data is removed (metrics, reports, integrations)",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client account owner, I want to manage which users have access to my account so that I can control who can view and modify my data.",
    title: "Manage User Access Permissions",
    tags: ["epic:permissions", "priority:medium", "mvp:v2"],
    criteria: [
      %{description: "Client can revoke a user access at any time", verified: false},
      %{
        description: "List shows user or agency name, access level, date granted, and whether they are account originator",
        verified: false
      },
      %{
        description: "Client can view list of all users with access to their account",
        verified: false
      },
      %{
        description: "Account originator cannot have their access revoked, only ownership can be transferred",
        verified: false
      },
      %{
        description: "System logs all permission changes with timestamp and user who made change",
        verified: false
      },
      %{
        description: "When access is revoked, user immediately loses ability to view client data",
        verified: false
      },
      %{
        description: "Client can modify a user access level to upgrade or downgrade permissions",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want to connect my marketing platforms (Google Ads, Facebook Ads, Google Analytics) so that my marketing data can be automatically synced into the reporting system.",
    title: "Connect Marketing Platform via OAuth",
    tags: ["platform:facebook-ads", "platform:google-ads", "tech:oauth", "priority:high", "mvp:v1",
     "epic:integrations", "platform:google-analytics"],
    criteria: [
      %{
        description: "After successful authentication, user is redirected back to platform selection",
        verified: false
      },
      %{
        description: "User can initiate OAuth flow for supported platforms: Google Ads, Facebook Ads, Google Analytics",
        verified: false
      },
      %{
        description: "OAuth flow opens in popup or new tab with platform authentication",
        verified: false
      },
      %{
        description: "Platform connection belongs to client account and is not transferable to agency",
        verified: false
      },
      %{description: "Failed OAuth attempts show clear error messages", verified: false},
      %{
        description: "User sees confirmation that integration is active and ready to sync",
        verified: false
      },
      %{description: "Integration is saved only after successful OAuth completion", verified: false},
      %{
        description: "User can modify selected accounts later without re-authenticating",
        verified: false
      },
      %{
        description: "User can select which ad accounts or properties to sync from connected platform",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want to view all my connected platforms so that I can manage my integrations and understand what data is being synced.",
    title: "View and Manage Platform Integrations",
    tags: ["priority:high", "mvp:v1", "tech:oauth", "epic:integrations"],
    criteria: [
      %{
        description: "User can view list of all connected integrations (marketing and financial)",
        verified: false
      },
      %{
        description: "All integrations treated uniformly with no special QuickBooks UI",
        verified: false
      },
      %{
        description: "Each integration shows platform name, connected date, and sync status",
        verified: false
      },
      %{
        description: "User can see which ad accounts, properties, or income accounts are selected for each integration",
        verified: false
      },
      %{description: "User can modify selected accounts without re-authenticating", verified: false},
      %{description: "User can disconnect or remove an integration", verified: false},
      %{
        description: "Disconnecting shows warning that historical data will remain but no new data will sync",
        verified: false
      },
      %{description: "User can reconnect a previously disconnected platform", verified: false}
    ]
  },
  %{
    status: nil,
    description: "As an admin user, I want to manually trigger a data sync so that I can debug integration issues or get fresh data on demand.",
    title: "Manual Sync Trigger (Admin)",
    tags: ["epic:integrations", "mvp:v2", "priority:medium"],
    criteria: [
      %{
        description: "Clicking sync triggers immediate data pull for that integration",
        verified: false
      },
      %{description: "UI shows sync in progress with loading indicator", verified: false},
      %{
        description: "Upon completion, user sees success message with timestamp and records synced",
        verified: false
      },
      %{description: "If sync fails, error details are displayed", verified: false},
      %{
        description: "Manual sync does not interfere with automated daily sync schedule",
        verified: false
      },
      %{description: "Admin users see Sync Now button in integration settings", verified: false}
    ]
  },
  %{
    status: nil,
    description: "As an agency account owner, I want to automatically add team members from my organization so that I do not have to manually invite each employee.",
    title: "Agency Team Auto-Enrollment",
    tags: ["priority:low", "epic:permissions", "mvp:future"],
    criteria: [
      %{description: "Agency admin can disable auto-enrollment if desired", verified: false},
      %{
        description: "Team members automatically inherit access to all client accounts the agency manages",
        verified: false
      },
      %{
        description: "Agency can configure domain-based auto-enrollment for their email domain",
        verified: false
      },
      %{
        description: "Users who register with matching email domain are automatically added to agency account",
        verified: false
      },
      %{
        description: "Auto-enrolled users get default access level set by agency admin",
        verified: false
      },
      %{
        description: "Agency admin can view and manage all auto-enrolled team members",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As an agency user, I want to easily switch between client accounts I have access to so that I can efficiently manage multiple clients.",
    title: "Agency Views and Manages Client Accounts",
    tags: ["priority:medium", "epic:permissions", "mvp:v2"],
    criteria: [
      %{
        description: "Each client listing shows access level and origination status",
        verified: false
      },
      %{
        description: "Agency can switch between client accounts via account switcher",
        verified: false
      },
      %{
        description: "Agency with account manager access can modify reports and integrations but not delete account or manage users",
        verified: false
      },
      %{description: "Current client context is clearly displayed in navigation", verified: false},
      %{
        description: "Agency with read-only access can only view reports and dashboards",
        verified: false
      },
      %{
        description: "If agency originated the client account, they see Originator badge",
        verified: false
      },
      %{
        description: "Agency cannot see other users who have access to the client account unless they have admin access",
        verified: false
      },
      %{
        description: "Agency with admin access can do everything except delete the account",
        verified: false
      },
      %{description: "Agency sees list of all client accounts they have access to", verified: false}
    ]
  },
  %{
    status: nil,
    description: "As a system, I want to automatically sync data from all connected platforms daily so that user data stays fresh without manual intervention.",
    title: "Automated Daily Data Sync",
    tags: ["mvp:v1", "priority:high", "epic:integrations"],
    criteria: [
      %{
        description: "Sync pulls new data from all active integrations for all accounts",
        verified: false
      },
      %{
        description: "System runs daily sync job at scheduled time (e.g., 2 AM UTC)",
        verified: false
      },
      %{
        description: "Default date ranges exclude today to avoid showing zero for incomplete day",
        verified: false
      },
      %{description: "Sync errors are logged with details for debugging", verified: false},
      %{
        description: "Failed syncs are automatically retried up to 3 times with exponential backoff",
        verified: false
      },
      %{description: "OAuth tokens are automatically refreshed when needed", verified: false},
      %{
        description: "Sync retrieves metrics, review data, and financial data for each day",
        verified: false
      },
      %{
        description: "Financial data (debits and credits) is stored as metrics alongside marketing metrics",
        verified: false
      },
      %{
        description: "On first sync after connection, system backfills all available historical data from platform",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As an admin user, I want to view sync history and status for each integration so that I can diagnose issues and understand data freshness.",
    title: "Sync Status and History",
    tags: ["epic:integrations", "priority:medium", "mvp:v2"],
    criteria: [
      %{description: "Failed syncs are highlighted with error details", verified: false},
      %{
        description: "Sync history shows: timestamp, status (success or failure), records synced, and any error messages",
        verified: false
      },
      %{description: "User can view detailed sync history (last 30 syncs minimum)", verified: false},
      %{description: "Each integration shows next scheduled sync time", verified: false},
      %{description: "Each integration shows last successful sync timestamp", verified: false},
      %{
        description: "User can filter sync history by status (all, success, failed)",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want my Google Analytics 4 property data to be synced daily so that website traffic and engagement metrics are available alongside my marketing spend and revenue data for correlation analysis.",
    title: "Sync Google Analytics 4 Data",
    tags: ["epic:integrations", "platform:google-analytics"],
    criteria: [
      %{
        description: "Subsequent daily syncs fetch data for yesterday only (avoids incomplete current-day data)",
        verified: false
      },
      %{
        description: "Sampled data responses are detected and flagged — system logs a warning and stores data with a sampling caveat",
        verified: false
      },
      %{
        description: "System handles GA4 API quota limits with exponential backoff and retry (default quota: 10 requests/second/project)",
        verified: false
      },
      %{
        description: "If GA4 API returns no data for a day (e.g., property had no traffic), a zero-value record is stored rather than a gap",
        verified: false
      },
      %{
        description: "GA4 metrics are mapped to canonical metric names in the cross-platform metric taxonomy (e.g., GA4 'sessions' maps to canonical 'sessions')",
        verified: false
      },
      %{
        description: "GA4-specific metrics that have no canonical equivalent are stored as platform-specific metrics labeled 'Google Analytics: [metric name]'",
        verified: false
      },
      %{
        description: "Data fetched is scoped to the date range dimension only — no other dimensions (e.g., source/medium) are stored at this stage",
        verified: false
      },
      %{
        description: "Sync failures for a GA4 property are logged with the API error response and surfaced in Sync Status and History",
        verified: false
      },
      %{
        description: "System syncs the following GA4 metrics as core daily values: activeUsers, active7DayUsers, active28DayUsers, newUsers, engagedSessions, sessions, userEngagementDuration, screenPageViews, eventCount, keyEvents, scrolledUsers",
        verified: false
      },
      %{
        description: "Because GA4's runReport endpoint has a 10-metric limit per request, metrics are fetched in chunks of 10 and results are merged by date before storage; the final stored data is identical to a single-request response would be",
        verified: false
      },
      %{
        description: "Because GA4's runReport endpoint has a 10-metric limit per request, metrics are fetched in chunks of 10 and results are merged by date before storage; the final stored data is equivalent to what a single-request response would contain",
        verified: false
      },
      %{
        description: "System fetches GA4 data using the Google Analytics Data API v1 (runReport endpoint), not the Universal Analytics API",
        verified: false
      },
      %{
        description: "Data is fetched per GA4 property selected during OAuth connection",
        verified: false
      },
      %{
        description: "Each metric is stored as a daily time-series value keyed to the property and client account",
        verified: false
      },
      %{
        description: "On first sync, system backfills up to 548 days of historical GA4 data (approximately 18 months); on subsequent syncs, fetches from the day after the last stored metric date",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want my Google Search Console data synced daily so that organic search performance metrics are available alongside my paid advertising and revenue data for correlation analysis.",
    title: "Sync Google Search Console Data",
    tags: ["epic:integrations", "platform:google-search-console"],
    criteria: [
      %{
        description: "System fetches data using the Google Search Console API (webmasters v3, searchanalytics.query endpoint) authenticated via Google OAuth2 with webmasters.readonly scope — reuses the same Google OAuth token as GA4 and Google Ads",
        verified: false
      },
      %{
        description: "Sync failures are logged with full error context including siteUrl, customerName, and dateRange and surfaced in Sync Status and History",
        verified: false
      },
      %{
        description: "On first sync, backfill window is determined by the service layer (consistent with other integrations at 548 days); subsequent syncs fetch from day after last stored metric date",
        verified: false
      },
      %{
        description: "Token expiry is checked before each API call; if expired, a refresh is attempted using the stored refresh token; if refresh fails, the existing token is used and the API call proceeds anyway",
        verified: false
      },
      %{
        description: "Dimension-scoped metric keys are formatted as '{metricKey}_{dimension}' (e.g., 'clicks_date'); overall metric keys are unscoped (e.g., 'clicks')",
        verified: false
      },
      %{
        description: "ARCHITECTURAL NOTE: Unlike other integrations, the fetcher writes directly to the database internally rather than returning raw data to a separate formatter/index layer — this is inconsistent with the rest of the integration architecture and should be refactored",
        verified: false
      },
      %{
        description: "Metrics are stored via upsert keyed on (customerName, platformExternalId, externalLocationId, metricKey, date) — re-runs are safe and idempotent, unlike the other ad platform integrations which use insert",
        verified: false
      },
      %{
        description: "Daily metrics use the date key from the API response; overall/aggregate metrics have no date key and default to current date — KNOWN BUG: overall metrics should not be stored without a valid date anchor",
        verified: false
      },
      %{
        description: "Core metrics synced per day: clicks, impressions, ctr (click-through rate), position (average search position)",
        verified: false
      },
      %{
        description: "Two API calls are made per sync: one with no dimensions (overall aggregate for the period) and one with dimensions: ['date'] (daily breakdown)",
        verified: false
      },
      %{
        description: "Data is fetched per site URL (googleConsoleSiteUrl) configured per customer in config.json; customers without a site URL are skipped",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want my Facebook Ads account data to be synced daily so that advertising spend, reach, and conversion metrics are available alongside my other platform data for correlation analysis.",
    title: "Sync Facebook Ads Data",
    tags: ["platform:facebook-ads", "epic:integrations"],
    criteria: [
      %{
        description: "Rows missing date_start are skipped with a warning; non-numeric metric values are skipped silently",
        verified: false
      },
      %{
        description: "System fetches data using facebook-nodejs-business-sdk, calling account.getInsights() at account level with time_increment: 1 (daily breakdown)",
        verified: false
      },
      %{
        description: "Data is fetched per facebookAdsAccountId from config; the 'act_' prefix is added by the fetcher at call time, not stored in config",
        verified: false
      },
      %{
        description: "Authentication uses a dedicated Facebook OAuth flow separate from Google OAuth, requiring FACEBOOK_APP_ID, FACEBOOK_APP_SECRET, and ads_read scope",
        verified: false
      },
      %{
        description: "Metrics are fetched at account level only — one row per day; no campaign, adset, or ad segmentation at this stage",
        verified: false
      },
      %{
        description: "Core scalar metrics synced daily: impressions, reach, clicks, spend, cpp, unique_clicks, unique_ctr, frequency, cost_per_ad_click, cost_per_conversion",
        verified: false
      },
      %{
        description: "The 'actions' API field is expanded from array into flat keys as 'actions:{action_type}' for: link_click, page_engagement, post_engagement, post_reaction, comment, like, share, video_view, lead, purchase, complete_registration, add_to_cart, checkout",
        verified: false
      },
      %{
        description: "The 'cost_per_action_type' field is expanded into flat keys as 'cost_per_action_type:{action_type}' for the same action type list",
        verified: false
      },
      %{
        description: "Video completion metrics (video_p25/50/75/100_watched_actions) are arrays — only the video_view action_type entry is extracted and stored as a scalar per metric",
        verified: false
      },
      %{
        description: "On first sync, system backfills 180 days of history; subsequent syncs fetch from the day after the last stored metric date",
        verified: false
      },
      %{
        description: "Sync uses retryWithBackoff with 3 retries and 2-second initial delay; Facebook API errors are extracted from error.response.error",
        verified: false
      },
      %{
        description: "Polly HTTP record/replay is initialized per fetch and stopped in the finally block — testing tool only, must not affect production sync",
        verified: false
      },
      %{
        description: "Sync failures are logged with full error details and surfaced in Sync Status and History",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want my Google Business Profile engagement metrics synced daily so that visibility and interaction data (impressions, calls, direction requests, website clicks) are available alongside my other platform data for correlation analysis.",
    title: "Sync Google Business Profile Performance Metrics",
    tags: ["platform:google-business", "epic:integrations"],
    criteria: [
      %{
        description: "The following metrics are fetched as daily time series: BUSINESS_IMPRESSIONS_DESKTOP_MAPS, BUSINESS_IMPRESSIONS_DESKTOP_SEARCH, BUSINESS_IMPRESSIONS_MOBILE_MAPS, BUSINESS_CONVERSATIONS, BUSINESS_DIRECTION_REQUESTS, CALL_CLICKS, WEBSITE_CLICKS, BUSINESS_BOOKINGS, BUSINESS_FOOD_ORDERS, BUSINESS_FOOD_MENU_CLICKS",
        verified: false
      },
      %{
        description: "Data is fetched per location ID listed in customerConfig.includedLocations, scoped under the customer's googleBusinessAccountId",
        verified: false
      },
      %{
        description: "This integration is distinct from the GMB Reviews integration (story 513) — both use the same account and location config but call different APIs and store different data under different platformServiceType values ('mybusiness' vs 'mybusiness-reviews')",
        verified: false
      },
      %{
        description: "Per-customer failures are caught and logged but do not halt processing of other customers; a summary of successes and failures is returned",
        verified: false
      },
      %{
        description: "Sync uses prisma.metric.create (insert not upsert) — re-running without clearing existing data will cause unique constraint violations; KNOWN LIMITATION: should be migrated to upsert consistent with the GSC integration",
        verified: false
      },
      %{
        description: "System fetches data using the Google Business Profile Performance API v1 (businessprofileperformance, locations.fetchMultiDailyMetricsTimeSeries endpoint) authenticated via Google OAuth2",
        verified: false
      },
      %{
        description: "Location details (title, storeCode) are fetched per location during sync to generate the metric label",
        verified: false
      },
      %{
        description: "Metric values are stored as integers (parseInt); null or missing values are stored as 0",
        verified: false
      },
      %{
        description: "Date arithmetic for the API call offsets the start date by +1 day — this is intentional to avoid re-fetching the last stored date",
        verified: false
      },
      %{
        description: "On first sync, system backfills up to 548 days of historical data; subsequent syncs fetch from the day after the last stored metric date for that location",
        verified: false
      },
      %{
        description: "Metrics are stored at location level (externalLocationId populated) with platformServiceType 'mybusiness' — one row per metric key per day per location",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want my Google Business Profile reviews synced so that review volume and ratings are available as daily metrics alongside my marketing and financial data for correlation analysis.",
    title: "Sync Google Business Profile Reviews",
    tags: ["epic:integrations", "platform:google-business"],
    criteria: [
      %{
        description: "Only BUSINESS_REVIEW_DAILY_COUNT is stored as a Metric record per day per location — averageRating and totalReviews are calculated during aggregation but not currently persisted as separate metric rows",
        verified: false
      },
      %{
        description: "All reviews are fetched via paginated requests (pageSize: 100, orderBy: updateTime desc) until no nextPageToken is returned — full history is always retrieved, not a windowed date range",
        verified: false
      },
      %{
        description: "Each review is stored in the Review table with: externalAccountId, externalLocationId, externalReviewId, reviewerName, rating (Google enum ONE-FIVE converted to integer 1-5), comment, reply, replyDate, reviewDate, status (PUBLISHED), and metadata (reviewType, languageCode)",
        verified: false
      },
      %{
        description: "KNOWN LIMITATION: Before each sync run, all existing Review records and all Metric records with keys prefixed 'BUSINESS_REVIEW_' are fully deleted before re-inserting — sync is a full rebuild; if sync fails midway, all historical data is lost until next successful run. Preferred future behavior: upsert on externalReviewId instead.",
        verified: false
      },
      %{
        description: "After reviews are stored, the aggregator walks day-by-day from earliest to latest review date calculating for each day: dailyReviewCount (reviews on that exact day), totalReviews (rolling count of all reviews up to that day), and averageRating (rolling average of all ratings up to that day",
        verified: false
      },
      %{
        description: "Sync processes all locations listed in customerConfig.includedLocations for each customer; customers without googleBusinessAccountId are skipped",
        verified: false
      },
      %{
        description: "Metrics are stored at location level (externalLocationId is populated), unlike the ad platform integrations which store at account level with null locationId",
        verified: false
      },
      %{
        description: "Sync failures for individual customers are caught and logged but do not halt processing of other customers; a summary of successes and failures is returned at the end",
        verified: false
      },
      %{
        description: "Location details (title, storeCode) are fetched during metric formatting to generate the metric label — if location details are unavailable the sync for that location fails with an error",
        verified: false
      },
      %{
        description: "System fetches reviews using the Google My Business API v4 (mybusiness.googleapis.com/v4) via direct HTTP with a Google OAuth access token — not the Analytics or Ads client libraries",
        verified: false
      },
      %{
        description: "Reviews are fetched per location ID under the customer's googleBusinessAccountId; the 'locations/' prefix is stripped from location IDs before API calls",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want my Google Ads account data to be synced daily so that advertising spend and performance metrics are available alongside my other platform data for correlation analysis.",
    title: "Sync Google Ads Data",
    tags: ["epic:integrations", "platform:google-ads"],
    criteria: [
      %{
        description: "On first sync, system backfills up to 548 days of historical data; subsequent syncs fetch from the day after the last stored metric date",
        verified: false
      },
      %{
        description: "cost_micros is always divided by 1,000,000 before storage so all cost values are in standard currency units",
        verified: false
      },
      %{
        description: "Sync uses retryWithBackoff with up to 3 retries and 2-second initial delay for transient API errors",
        verified: false
      },
      %{
        description: "Google Ads API errors are extracted from error.response.errors[0] and surfaced with full context (customerId, dateRange, errorCode)",
        verified: false
      },
      %{
        description: "System fetches Google Ads data using the Google Ads API via the google-ads-api client library, querying the 'customer' entity with date segments",
        verified: false
      },
      %{
        description: "Data is fetched per Google Ads customer ID (googleAdsPropertyId) configured for each account",
        verified: false
      },
      %{
        description: "System requires a valid GOOGLE_DEVELOPER_TOKEN environment variable and a manager account ID (GOOGLE_MANAGER_ACCOUNT_ID) to authenticate API calls",
        verified: false
      },
      %{
        description: "OAuth refresh token from the stored Google token set is used per request — no separate Google Ads OAuth flow",
        verified: false
      },
      %{
        description: "System syncs the following metrics as core daily values: clicks, impressions, cost_micros (converted to cost by dividing by 1,000,000), all_conversions, conversions",
        verified: false
      },
      %{
        description: "Metrics are fetched at account level only (customer entity, no campaign or ad group segmentation) — one row per day per metric",
        verified: false
      },
      %{
        description: "Data fetched is segmented by date only — no additional dimensions (e.g., campaign, device, network) are stored at this stage; adding dimensions would require schema changes and re-aggregation logic before correlation can be run",
        verified: false
      },
      %{
        description: "Sync failures are logged with full error details and surfaced in Sync Status and History",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want my QuickBooks income account data synced daily so that credit transactions (money coming into the business) are available as a metric for correlation analysis against my marketing activity.",
    title: "Sync QuickBooks Account Transaction Data",
    tags: ["platform:quickbooks", "epic:integrations"],
    criteria: [
      %{
        description: "Data is fetched per income account selected by the user during OAuth connection setup; multiple selected accounts are each synced independently",
        verified: false
      },
      %{
        description: "System connects to QuickBooks via the OAuth token established in the Connect Financial Platform via OAuth story (435) — no separate auth flow",
        verified: false
      },
      %{
        description: "Sync failures are logged with full error context including accountId, customerName, and dateRange and surfaced in Sync Status and History",
        verified: false
      },
      %{
        description: "Days with no transactions are stored as zero-value records rather than gaps, to preserve continuity for correlation calculations",
        verified: false
      },
      %{
        description: "On first sync, system backfills up to 548 days of historical data; subsequent syncs fetch from the day after the last stored metric date",
        verified: false
      },
      %{
        description: "platformExternalId is set to the QuickBooks account ID; externalLocationId is null (financial data has no location concept)",
        verified: false
      },
      %{
        description: "Metric keys are: QUICKBOOKS_ACCOUNT_DAILY_CREDITS and QUICKBOOKS_ACCOUNT_DAILY_DEBITS",
        verified: false
      },
      %{
        description: "Each metric is stored as a daily aggregate value — individual transactions are not stored, only the sum of credits and sum of debits per account per day",
        verified: false
      },
      %{
        description: "Debits (money out) are also stored as a separate metric so spend patterns can optionally be correlated as well",
        verified: false
      },
      %{
        description: "Credits (money in) are stored as the primary metric — this represents revenue flowing into the account and is the target variable for correlation analysis",
        verified: false
      },
      %{
        description: "For each account, the system fetches debit and credit transaction totals aggregated by day using the QuickBooks Reports or Transactions API",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want to be notified when my platform credentials expire so that I can reconnect and resume data syncing.",
    title: "Handle Expired or Invalid OAuth Credentials",
    tags: ["tech:oauth", "priority:low", "epic:integrations"],
    criteria: [
      %{description: "After successful reconnection, sync resumes automatically", verified: false},
      %{description: "User can click Reconnect button to re-initiate OAuth flow", verified: false},
      %{description: "User receives email notification about expired credentials", verified: false},
      %{description: "User sees warning indicator on integration in dashboard", verified: false},
      %{
        description: "When OAuth token refresh fails, integration status changes to Needs Reconnection",
        verified: false
      },
      %{
        description: "System does not delete historical data when credentials expire",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As an agency account owner, I want to configure white-label branding for my agency so that clients see my brand when accessing reports.",
    title: "Agency White-label Configuration",
    tags: ["priority:low", "epic:white-label", "mvp:v2"],
    criteria: [
      %{description: "Changes preview in real-time before saving", verified: false},
      %{
        description: "Agency can configure custom subdomain (e.g., reports.andersonthefish.com)",
        verified: false
      },
      %{
        description: "Agency can set custom color scheme (primary, secondary, accent colors)",
        verified: false
      },
      %{description: "Agency can upload custom logo (supports PNG, JPG, SVG)", verified: false},
      %{
        description: "No Anderson Analytics branding visible on white-labeled instances",
        verified: false
      },
      %{
        description: "Custom subdomain requires DNS verification before activation",
        verified: false
      },
      %{description: "White-label settings are stored at agency account level", verified: false},
      %{description: "Agency can reset to default branding", verified: false}
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want to see all my metrics from all platforms in one unified view so that I can understand my complete marketing and financial picture.",
    title: "View All Metrics Dashboard",
    tags: ["mvp:v1", "epic:visualization", "priority:high"],
    criteria: [
      %{description: "User can filter by platform, date range, or metric type", verified: false},
      %{
        description: "User can access All Metrics dashboard showing data from all connected platforms",
        verified: false
      },
      %{
        description: "Dashboard displays both marketing metrics and financial metrics with no distinction",
        verified: false
      },
      %{
        description: "User can select date range: last 7 days, 30 days, 90 days, all time, custom",
        verified: false
      },
      %{
        description: "Date ranges default to last X days from yesterday to avoid incomplete current day",
        verified: false
      },
      %{description: "Dashboard updates dynamically when filters change", verified: false},
      %{
        description: "If no integrations connected, dashboard shows onboarding prompts",
        verified: false
      },
      %{description: "All visualizations use Vega-Lite", verified: false}
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want calculated metrics like cost-per-click or conversion rate to be aggregated correctly when viewed across time periods or platforms, so that I see mathematically accurate numbers rather than misleading averages of averages.",
    title: "Correct Aggregation of Derived and Calculated Metrics",
    tags: ["epic:metrics", "priority:high", "mvp:v1"],
    criteria: [
      %{
        description: "System never averages a derived metric directly across rows - it always re-derives from aggregated components",
        verified: false
      },
      %{
        description: "Derived metric definitions are stored as metadata and can be extended for new metric types",
        verified: false
      },
      %{
        description: "If a component metric has missing data for a time period, the derived metric for that period reflects the gap rather than silently producing incorrect values",
        verified: false
      },
      %{
        description: "Derived metrics display identically to raw metrics in dashboards and reports - the aggregation logic is transparent to the user",
        verified: false
      },
      %{
        description: "System distinguishes between raw/additive metrics (e.g., clicks, spend, impressions) and derived/calculated metrics (e.g., CPC, CTR, conversion rate, ROAS)",
        verified: false
      },
      %{
        description: "Derived metrics are defined by a formula referencing their component raw metrics (e.g., CPC = total spend / total clicks)",
        verified: false
      },
      %{
        description: "When aggregating derived metrics across time periods (e.g., daily to weekly), system sums the component metrics first then calculates the derived value from the aggregated components",
        verified: false
      },
      %{
        description: "When aggregating derived metrics across multiple platforms or ad accounts, system sums the component metrics first then calculates the derived value from the aggregated components",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want the system to recognize that equivalent metrics from different platforms represent the same concept (e.g., a Google Ads click is the same as a Facebook Ads click), so that I can accurately compare and aggregate the same metric across platforms without manual reconciliation.",
    title: "Cross-Platform Metric Normalization and Mapping",
    tags: ["epic:metrics", "mvp:v1", "priority:high"],
    criteria: [
      %{
        description: "Mapped metrics can be aggregated across platforms in dashboards and reports using canonical names",
        verified: false
      },
      %{
        description: "Derived metrics (e.g., CPC) that reference canonical component metrics automatically work across platforms once their components are mapped",
        verified: false
      },
      %{
        description: "New platform integrations can define their metric mappings without requiring changes to existing canonical definitions",
        verified: false
      },
      %{
        description: "Metric mappings account for known semantic differences (e.g., different attribution windows or counting methods) and surface these as warnings or footnotes when comparing",
        verified: false
      },
      %{
        description: "Mapped metrics can be compared side-by-side across platforms (e.g., Google Ads clicks vs Facebook Ads clicks on the same chart)",
        verified: false
      },
      %{
        description: "Users can view which platform metrics are mapped to which canonical metrics",
        verified: false
      },
      %{
        description: "When a platform metric does not have a direct equivalent in the canonical taxonomy, it is stored as a platform-specific metric and clearly labeled as such",
        verified: false
      },
      %{
        description: "Each platform integration defines mappings from its native metric names to canonical metrics (e.g., Google Ads 'Clicks' and Facebook Ads 'Link Clicks' both map to canonical 'clicks')",
        verified: false
      },
      %{
        description: "System maintains a canonical metric taxonomy (e.g., 'clicks', 'spend', 'impressions', 'conversions') that platform-specific metrics map to",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want to access pre-built dashboard templates so that I can quickly get insights without building custom reports.",
    title: "Default Canned Dashboards",
    tags: ["mvp:v2", "priority:low", "epic:visualization"],
    criteria: [
      %{
        description: "User can select template and it auto-populates with their data",
        verified: false
      },
      %{description: "Canned dashboards use vega lite visualizations", verified: false},
      %{description: "User can customize canned dashboards and save as their own", verified: false},
      %{description: "Canned dashboards include line charts shoting base metrics", verified: false},
      %{
        description: "System provides default dashboard templates (e.g., Marketing Overview, Revenue Analysis, Platform Comparison)",
        verified: false
      },
      %{description: "User can reset to default template if they have customized", verified: false},
      %{description: "Canned dashboards update automatically as new data syncs", verified: false}
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want to view rendered Vega-Lite visualizations within my dashboards and reports so that I can consume the charts I or my team have created.",
    title: "Render Saved Visualizations in Dashboards and Reports",
    tags: ["epic:visualization", "mvp:v1", "priority:medium"],
    criteria: [
      %{
        description: "The saved Vega-Lite spec is a template with no embedded data values — data is fetched and injected at render time from the bound metrics",
        verified: false
      },
      %{
        description: "User can view a saved Vega-Lite visualization rendered inline within a dashboard or report",
        verified: false
      },
      %{
        description: "A visualization can display multiple metrics as separate series on the same chart",
        verified: false
      },
      %{
        description: "If a visualization spec is missing or malformed, a clear error state is shown rather than a blank panel",
        verified: false
      },
      %{
        description: "The visualization renders correctly across the supported chart types (bar, line, area, scatter, and any other valid Vega-Lite spec)",
        verified: false
      },
      %{
        description: "User can resize or expand a visualization within the report layout",
        verified: false
      },
      %{
        description: "Visualizations sourced from the visualization library are displayed with their saved name and last-updated timestamp",
        verified: false
      },
      %{
        description: "Visualizations are permanently bound to one or more metrics via a join table, not by embedding data in the spec",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want to generate and iteratively refine Vega-Lite visualizations through an LLM chat interface so that I can build custom charts from my data without writing specs manually.",
    title: "LLM-Driven Visualization Authoring",
    tags: ["tech:vega-lite", "priority:high", "tech:llm", "epic:visualization", "mvp:v2"],
    criteria: [
      %{
        description: "When the LLM generates or updates a spec, the system automatically creates or updates visualization_metrics join table entries to bind every referenced metric name to the visualization",
        verified: false
      },
      %{
        description: "Multi-metric visualizations use a Vega-Lite layer with a separate named data source per metric",
        verified: false
      },
      %{
        description: "The LLM generates specs using Vega-Lite named data sources (e.g. \"data\": {\"name\": \"metricName\"}) rather than embedding data values, consistent with the template storage format",
        verified: false
      },
      %{
        description: "The system provides the account's available metric names to the LLM so it can reference valid data sources",
        verified: false
      },
      %{
        description: "The LLM receives relevant Vega-Lite v5 schema documentation as context, scoped to the chart type being requested, so it can produce valid specs for advanced chart types",
        verified: false
      },
      %{
        description: "The chat panel renders the full conversation history — user messages and assistant responses — for the duration of the editing session",
        verified: false
      },
      %{
        description: "When the LLM returns an updated spec, both the spec editor drawer and the live preview update automatically without a page reload",
        verified: false
      },
      %{
        description: "The LLM receives the current Vega-Lite spec as context with each follow-up message, enabling iterative editing of the same artifact",
        verified: false
      },
      %{
        description: "User can edit the Vega-Lite spec directly in the spec editor drawer; changes are reflected in the live preview without requiring an LLM round-trip",
        verified: false
      },
      %{
        description: "If the LLM produces a spec referencing a metric name not present in the account's available metrics, the chat panel surfaces an error identifying the unresolvable metric",
        verified: false
      },
      %{
        description: "Saved visualizations appear in the visualization library accessible from the report builder (criterion 5055)",
        verified: false
      },
      %{
        description: "User can name and save the visualization, making it available for inclusion in custom reports (criterion 5054)",
        verified: false
      },
      %{
        description: "User can open a visualization authoring workspace at /app/visualizations/:id/edit that shows three panels: a chat panel on the left, a live chart preview in the center, and a slide-out Vega-Lite JSON spec editor on the right (criterion 5047)",
        verified: false
      },
      %{
        description: "User can describe a desired visualization in natural language via the chat panel; submitting the message dispatches a send_chat event that calls the LLM and streams the response back into the chat panel",
        verified: false
      },
      %{
        description: "The LLM receives the full current Vega-Lite spec as context on every message, enabling iterative refinement without regenerating the spec from scratch",
        verified: false
      },
      %{
        description: "Generated specs reference account metrics by name using Vega-Lite named data sources (\"data\": {\"name\": \"metricName\"}) rather than embedding raw data values, making specs portable reusable templates",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want to access my saved reports easily so that I can review important metrics regularly.",
    title: "View and Navigate Saved Reports",
    tags: ["epic:visualization", "mvp:v2", "priority:low"],
    criteria: [
      %{description: "Report maintains selected date range from last viewing", verified: false},
      %{description: "User can search reports by name", verified: false},
      %{description: "Clicking report opens it in full view", verified: false},
      %{description: "User can view list of all saved reports", verified: false},
      %{description: "Reports are sorted by last modified date", verified: false},
      %{description: "User can set report as favorite for quick access", verified: false},
      %{description: "User can duplicate reports to create variations", verified: false}
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want to see my agency branding when they have originated my account so that the experience feels professional and cohesive.",
    title: "Client Views White-labeled Interface",
    tags: ["priority:low", "mvp:v2", "epic:white-label"],
    criteria: [
      %{description: "Agency color scheme is applied throughout interface", verified: false},
      %{description: "Agency logo appears in navigation header", verified: false},
      %{
        description: "When client accesses system via agency custom subdomain, they see agency branding",
        verified: false
      },
      %{
        description: "White-label branding does not affect functionality, only visual appearance",
        verified: false
      },
      %{
        description: "Client can still customize their own dashboards regardless of white-labeling",
        verified: false
      },
      %{
        description: "If agency is account originator, white-labeling is always applied for that client",
        verified: false
      },
      %{
        description: "When client accesses via main domain, they see default branding",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As an invited user, I want to accept a client invitation so that I can access their account and provide services.",
    title: "Agency or User Accepts Client Invitation",
    tags: ["mvp:v2", "priority:medium", "epic:permissions"],
    criteria: [
      %{
        description: "Upon acceptance, user account is granted specified access level to client account",
        verified: false
      },
      %{description: "User clicks invitation link and is taken to acceptance page", verified: false},
      %{description: "If not logged in, user is prompted to log in or register", verified: false},
      %{description: "Expired invitations show clear error message", verified: false},
      %{description: "Already-accepted invitations cannot be reused", verified: false},
      %{
        description: "If invitee is part of an agency, entire agency team gets access based on agency team structure",
        verified: false
      },
      %{
        description: "User sees client account added to their account switcher or list",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want to specify which metrics are my business goals so that the system can identify what drives those outcomes.",
    title: "Select Goal Metrics for Correlation",
    tags: ["epic:correlation", "priority:high", "mvp:v1"],
    criteria: [
      %{description: "User can access Goal Metrics configuration from menu", verified: false},
      %{
        description: "When user selects goal metrics, system queues correlation analysis",
        verified: false
      },
      %{
        description: "User can select one or more metrics as goals (e.g., revenue account from QuickBooks)",
        verified: false
      },
      %{
        description: "Selected goal metrics are highlighted or badged in metric lists",
        verified: false
      },
      %{description: "User can modify goal metrics at any time", verified: false},
      %{description: "System stores goal metrics per account", verified: false}
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want to see which marketing metrics correlate most with my goal metrics so that I can focus on activities that drive business results.",
    title: "Automated Correlation Analysis",
    tags: ["mvp:v1", "priority:high", "epic:correlation"],
    criteria: [
      %{
        description: "Correlation runs against ALL metrics (financial and marketing treated the same)",
        verified: false
      },
      %{
        description: "System automatically calculates correlations between all metrics and selected goal metric(s)",
        verified: false
      },
      %{description: "Correlations are calculated daily after data sync completes", verified: false},
      %{
        description: "System tests multiple time lags (0-30 days) for each metric to automatically find optimal lag",
        verified: false
      },
      %{
        description: "System selects lag with highest absolute correlation value for each metric",
        verified: false
      },
      %{description: "Correlation calculations use daily aggregated data", verified: false},
      %{
        description: "Only correlations meeting minimum data threshold are calculated (e.g., 30+ days of data)",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want to see AI-curated correlation insights so that I can quickly understand what matters most without analyzing raw data.",
    title: "View Correlation Analysis Results (Smart/AI Mode)",
    tags: ["epic:correlation", "mvp:v2", "priority:low"],
    criteria: [
      %{description: "Mode selection (Raw vs Smart) is saved per user preference", verified: false},
      %{
        description: "Only correlations above minimum threshold are shown (e.g., absolute value greater than 0.3)",
        verified: false
      },
      %{
        description: "Results are presented with explanations (e.g., Google Ads spend shows strong correlation with revenue at 7-day lag)",
        verified: false
      },
      %{
        description: "AI can highlight which correlations are most meaningful based on context",
        verified: false
      },
      %{description: "User can still access full ranked list if desired", verified: false},
      %{
        description: "In Smart/AI mode: analysis shows top 5 positive and top 5 negative correlations",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want to view raw correlation analysis results so that I can analyze data myself without AI suggestions.",
    title: "View Correlation Analysis Results (Raw Mode)",
    tags: ["mvp:v1", "epic:correlation", "priority:medium"],
    criteria: [
      %{description: "User can access correlation analysis from main navigation", verified: false},
      %{
        description: "Each correlation shows: metric name, correlation coefficient, optimal lag in days, time period analyzed",
        verified: false
      },
      %{
        description: "If insufficient data exists, user sees message explaining minimum requirements",
        verified: false
      },
      %{description: "Results update when user changes time window or filters", verified: false},
      %{
        description: "User can select different time windows for analysis (30 days, 90 days, all time)",
        verified: false
      },
      %{description: "User can toggle between Raw and Smart/AI modes", verified: false},
      %{description: "User can filter by platform or metric type", verified: false},
      %{description: "User can view both positive and negative correlations", verified: false},
      %{
        description: "User can sort by: correlation strength, metric name, platform, lag time",
        verified: false
      },
      %{
        description: "In Raw mode: analysis shows ranked list of ALL correlations (strongest to weakest)",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want to get AI-powered suggestions based on my correlation data so that I can make informed decisions about where to invest.",
    title: "AI Insights and Suggestions",
    tags: ["epic:ai-features", "priority:low", "mvp:future", "tech:llm"],
    criteria: [
      %{
        description: "AI analyzes correlation data and provides actionable recommendations (e.g., Increase Google Ads budget based on 0.85 correlation with revenue)",
        verified: false
      },
      %{description: "AI learns from feedback to improve future suggestions", verified: false},
      %{
        description: "User can provide feedback on suggestions (helpful or not helpful)",
        verified: false
      },
      %{
        description: "AI suggestions are based on correlation strength, trends, and business context",
        verified: false
      },
      %{
        description: "Clicking AI button shows context-specific insights or opens chat about that metric",
        verified: false
      },
      %{description: "Each chart or visualization can have an AI info button", verified: false},
      %{description: "User can enable AI Suggestions option in Smart mode", verified: false}
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want to chat with AI about my data so that I can ask questions and get insights in natural language.",
    title: "AI Chat for Data Exploration",
    tags: ["epic:ai-features", "mvp:future", "tech:llm", "priority:low"],
    criteria: [
      %{
        description: "User can ask questions like Why did my revenue drop last week",
        verified: false
      },
      %{description: "User can share chat insights with team members", verified: false},
      %{description: "Chat history is saved per user", verified: false},
      %{description: "AI can suggest visualizations or reports based on questions", verified: false},
      %{description: "AI has access to all metrics and correlation data to answer", verified: false},
      %{description: "Chat context includes relevant data from current view", verified: false},
      %{description: "User can open AI chat from any report or visualization", verified: false}
    ]
  },
  %{
    status: nil,
    description: "As a client account owner, I want to invite agencies or individual users to access my account so that they can help manage my marketing data and reporting.",
    title: "Client Invites Agency or Individual User Access",
    tags: ["epic:permissions", "priority:medium", "mvp:v2"],
    criteria: [
      %{
        description: "Invitation link is single-use and invalidated after acceptance or expiration",
        verified: false
      },
      %{
        description: "Client can send email invitation to any email address (agency or individual)",
        verified: false
      },
      %{
        description: "Invitation email contains secure link with expiration time of 7 days",
        verified: false
      },
      %{description: "Invitee receives invitation in their email inbox", verified: false},
      %{
        description: "Invitation includes client account name and access level being granted",
        verified: false
      },
      %{
        description: "Client can specify access level in invitation: read-only, account manager, or admin",
        verified: false
      },
      %{
        description: "Client can view pending invitations and cancel them before acceptance",
        verified: false
      },
      %{
        description: "Client can invite multiple agencies or users with different access levels",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As an account owner, I want to transfer ownership of my account to another user so that I can hand off the account when selling a client or changing primary contacts.",
    title: "Transfer Account Ownership",
    tags: ["mvp:future", "epic:permissions", "priority:low"],
    criteria: [
      %{
        description: "Previous owner access level changes based on their selection during transfer",
        verified: false
      },
      %{
        description: "Upon acceptance, ownership transfers completely to new owner",
        verified: false
      },
      %{
        description: "New owner must authenticate or verify identity before accepting",
        verified: false
      },
      %{
        description: "Transfer wizard asks: Do you want to make a copy in your own account, Do you want to remain as admin after transfer",
        verified: false
      },
      %{
        description: "Transfer requires new owner to accept via email confirmation",
        verified: false
      },
      %{
        description: "Owner can transfer to existing user with account access or send transfer invitation to new email",
        verified: false
      },
      %{description: "Only current account owner can initiate ownership transfer", verified: false},
      %{
        description: "If account has originator relationship for white-label, originator status can optionally transfer too",
        verified: false
      },
      %{description: "All users are notified of ownership change", verified: false},
      %{
        description: "System logs ownership transfer with both parties confirmation",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a user with access to a client account, I want to revoke my own access so that I can cleanly end the relationship.",
    title: "User or Agency Self-Revokes Access",
    tags: ["priority:low", "mvp:future", "epic:permissions"],
    criteria: [
      %{
        description: "User cannot re-access account without new invitation from client",
        verified: false
      },
      %{
        description: "User can revoke their own access from client account settings",
        verified: false
      },
      %{description: "Confirmation prompt warns that this action cannot be undone", verified: false},
      %{
        description: "After revocation, client account is removed from user account list",
        verified: false
      },
      %{
        description: "Account originator cannot self-revoke and must transfer ownership first",
        verified: false
      },
      %{
        description: "Client is notified via email when user revokes their own access",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want to connect my QuickBooks account so that my revenue data can be correlated with marketing metrics.",
    title: "Connect Financial Platform via OAuth",
    tags: ["tech:oauth", "priority:high", "epic:integrations", "mvp:v1", "platform:quickbooks"],
    criteria: [
      %{description: "Failed OAuth attempts show clear error messages", verified: false},
      %{
        description: "Financial data (debits and credits) becomes just another metric in the system for correlation",
        verified: false
      },
      %{
        description: "User sees confirmation that QuickBooks is connected and ready to sync",
        verified: false
      },
      %{description: "Integration is saved only after successful OAuth completion", verified: false},
      %{
        description: "User can select multiple income accounts, system will sum debits and credits",
        verified: false
      },
      %{
        description: "After successful authentication, user can select which income accounts to track",
        verified: false
      },
      %{
        description: "OAuth flow authenticates user and grants access to financial data",
        verified: false
      },
      %{description: "User can initiate OAuth flow for QuickBooks", verified: false}
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want to create and save custom reports so that I can track specific metrics important to my business.",
    title: "Create and Save Custom Reports",
    tags: ["epic:visualization", "priority:medium", "mvp:v2"],
    criteria: [
      %{description: "User can create new report from template or blank canvas", verified: false},
      %{
        description: "User can insert a saved visualization from the visualization library as a component within a custom report, with the rendered chart appearing inline alongside other report elements",
        verified: false
      },
      %{
        description: "Reports can include metrics from any connected platform (marketing and financial)",
        verified: false
      },
      %{
        description: "User can add visualizations by selecting metrics and chart types",
        verified: false
      },
      %{
        description: "User can arrange visualizations in layout (drag and drop or grid)",
        verified: false
      },
      %{description: "User can delete saved reports", verified: false},
      %{description: "User can edit saved reports", verified: false},
      %{description: "Saved reports appear in user report list", verified: false},
      %{description: "User can name and save report", verified: false},
      %{description: "Report editor includes the canned vega lite editor", verified: false},
      %{description: "Reports use vega lite", verified: false}
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want the system to fetch and display all locations across my connected Google Business Profile accounts so that I can select which locations to include in syncing, with full support for customers who have locations spread across multiple GBP accounts.",
    title: "Fetch and Select Google Business Profile Locations Across Multiple Accounts",
    tags: [],
    criteria: [
      %{
        description: "Backfill behavior for newly added locations matches existing behavior: 548 days on first sync",
        verified: false
      },
      %{
        description: "Selected location IDs are stored in customerConfig.includedLocations as an array, prefixed with their accountId for unambiguous reference across multiple accounts",
        verified: false
      },
      %{
        description: "Each location row shows: account name (for disambiguation), location name/title, store code if present, and address",
        verified: false
      },
      %{
        description: "User is presented with the full location list and can select which locations to include in syncing (includedLocations config)",
        verified: false
      },
      %{
        description: "All locations from all accounts are merged into a single flat list for display and selection",
        verified: false
      },
      %{
        description: "Pagination is handled — system follows nextPageToken until all locations are retrieved for each account",
        verified: false
      },
      %{
        description: "Locations are fetched using the Google Business Profile API v1 (mybusinessbusinessinformation or mybusiness v4) with fields: name, title, storeCode, storefrontAddress, websiteUri, regularHours, primaryCategory",
        verified: false
      },
      %{
        description: "User can update location selection at any time without re-authenticating",
        verified: false
      },
      %{
        description: "If a location disappears from the API (e.g. deleted or access revoked), it is flagged in the UI rather than silently removed from sync config",
        verified: false
      },
      %{
        description: "Sync jobs for reviews (story 513) and performance metrics (story 517) are updated to iterate over all accounts in googleBusinessAccountIds — not just a single googleBusinessAccountId",
        verified: false
      },
      %{
        description: "System fetches all locations across all configured googleBusinessAccountIds (plural) — iterates over the array and calls accounts/{accountId}/locations for each",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a client user, I want to connect my Google Business Profile account(s) via OAuth so that the system can access my business locations and sync reviews and performance metrics across all of my GMB properties.",
    title: "Connect Google Business Profile via OAuth",
    tags: [],
    criteria: [
      %{
        description: "Integration is saved only after at least one account is selected and confirmed",
        verified: false
      },
      %{
        description: "User sees confirmation showing how many GMB accounts are connected and a prompt to proceed to location selection",
        verified: false
      },
      %{description: "Failed OAuth attempts show clear error messages", verified: false},
      %{
        description: "OAuth flow requests the following scopes: https://www.googleapis.com/auth/business.manage (or readonly equivalent) and reuses the existing Google OAuth token if already connected for Ads/GA4",
        verified: false
      },
      %{
        description: "After successful authentication, user is presented with a list of all Google Business Profile accounts they have access to (fetched from accounts.list API)",
        verified: false
      },
      %{
        description: "User can return to this settings page later to add or remove GMB accounts without re-authenticating via OAuth",
        verified: false
      },
      %{
        description: "If user previously connected a single googleBusinessAccountId (legacy singular field), migration path shows that account pre-selected and prompts confirmation",
        verified: false
      },
      %{
        description: "Selected GMB account IDs are saved to the customer's platform integration config as an array (googleBusinessAccountIds — plural)",
        verified: false
      },
      %{
        description: "Each selected account is displayed with its account name and account ID for clarity",
        verified: false
      },
      %{
        description: "User can select ONE OR MORE GMB accounts — multi-select is required as a single business may have locations spread across multiple GBP accounts",
        verified: false
      },
      %{
        description: "User can initiate OAuth flow for Google Business Profile from the integrations settings page",
        verified: false
      }
    ]
  },
  %{
    status: nil,
    description: "As a system, I want to derive daily rolling review metrics from the Review table regardless of source platform, so that review performance can be correlated with marketing and financial data across any platform that produces reviews.",
    title: "Calculate Rolling Review Metrics from Review Table",
    tags: ["epic:metrics"],
    criteria: [
      %{
        description: "For each location, the system calculates three metrics per day across the full date range from earliest to latest review date: dailyReviewCount (reviews with reviewDate on that exact day), totalReviews (rolling count of all reviews up to end of that day), averageRating (rolling average of all ratings up to end of that day)",
        verified: false
      },
      %{
        description: "Metric calculation is platform-agnostic — it operates on the Review table directly and produces identical output whether reviews came from Google Business Profile, Yelp, Trustpilot, or any future review source",
        verified: false
      },
      %{
        description: "Metrics are stored at location level (externalLocationId populated) — one row per metric key per day per location",
        verified: false
      },
      %{
        description: "All three metrics are persisted as Metric rows keyed as: BUSINESS_REVIEW_DAILY_COUNT, BUSINESS_REVIEW_TOTAL_COUNT, BUSINESS_REVIEW_AVERAGE_RATING",
        verified: false
      },
      %{
        description: "If no reviews exist for a location, no metrics are written and a warning is logged",
        verified: false
      },
      %{
        description: "Calculation is triggered after any review sync completes — it is not coupled to a specific platform sync; any sync that writes to the Review table should trigger recalculation for the affected locations",
        verified: false
      },
      %{
        description: "Existing metric rows for BUSINESS_REVIEW_* keys are deleted and recalculated on each run (rebuild model) until upsert-based incremental calculation is implemented",
        verified: false
      },
      %{
        description: "averageRating values are stored as floats rounded to 2 decimal places",
        verified: false
      }
    ]
  }
]
