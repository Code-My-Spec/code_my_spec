# Seed file for MetricFlow and Fuellytics projects
# Run with: mix run priv/repo/seeds/metricflow_and_fuellytics.exs
#
# Creates accounts, projects, stories, criteria, tags, and story_tags
# for the MetricFlow and Fuellytics demo projects.

alias CodeMySpec.Repo
import Ecto.Query

now = DateTime.utc_now() |> DateTime.truncate(:second)

# Helper: convert UUID string to binary for raw insert_all
uuid = &Ecto.UUID.dump!/1

# =============================================================================
# Accounts
# =============================================================================

accounts = [
  %{
    id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    name: "Anderson",
    slug: "anderson-the-fish",
    type: "team",
    inserted_at: now,
    updated_at: now
  },
  %{
    id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    name: "Fuelytics",
    slug: "fuelytics",
    type: "team",
    inserted_at: now,
    updated_at: now
  }
]

for account <- accounts do
  unless Repo.exists?(from a in "accounts", where: a.id == ^account.id) do
    Repo.insert_all("accounts", [account])
  end
end

# =============================================================================
# Projects
# =============================================================================

projects = [
  %{
    id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    name: "Metric FLow",
    description: "Metric flow is a multi-account reporting solution that aggregates metrics from multiple platforms, aggregates and correlates them to business goals.",
    status: "created",
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    name: "Fuelytics Web App",
    module_name: "Fuelytics",
    status: "created",
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  }
]

for project <- projects do
  unless Repo.exists?(from p in "projects", where: p.id == ^project.id) do
    Repo.insert_all("projects", [project])
  end
end

# =============================================================================
# Stories
# =============================================================================

stories = [
  %{
    id: 424,
    title: "User Registration and Account Creation",
    description: "As a new user, I want to register for an account so that I can access the reporting platform and manage my marketing data.",
    status: nil,
    priority: 1,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 425,
    title: "User Login and Session Management",
    description: "As a registered user, I want to log in securely so that I can access my account and data.",
    status: nil,
    priority: 2,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 426,
    title: "Multi-User Account Access",
    description: "As an account owner, I want to invite team members (both inside and outside my organization) to my account so that multiple people can access our data with appropriate permissions.",
    status: nil,
    priority: 3,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 427,
    title: "Agency Team Auto-Enrollment",
    description: "As an agency account owner, I want to automatically add team members from my organization so that I do not have to manually invite each employee.",
    status: nil,
    priority: 9,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 428,
    title: "Client Invites Agency or Individual User Access",
    description: "As a client account owner, I want to invite agencies or individual users to access my account so that they can help manage my marketing data and reporting.",
    status: nil,
    priority: 23,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 429,
    title: "Agency or User Accepts Client Invitation",
    description: "As an invited user, I want to accept a client invitation so that I can access their account and provide services.",
    status: nil,
    priority: 22,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 430,
    title: "Manage User Access Permissions",
    description: "As a client account owner, I want to manage which users have access to my account so that I can control who can view and modify my data.",
    status: nil,
    priority: 5,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 431,
    title: "Agency Views and Manages Client Accounts",
    description: "As an agency user, I want to easily switch between client accounts I have access to so that I can efficiently manage multiple clients.",
    status: nil,
    priority: 10,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 432,
    title: "User or Agency Self-Revokes Access",
    description: "As a user with access to a client account, I want to revoke my own access so that I can cleanly end the relationship.",
    status: nil,
    priority: 25,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 433,
    title: "Transfer Account Ownership",
    description: "As an account owner, I want to transfer ownership of my account to another user so that I can hand off the account when selling a client or changing primary contacts.",
    status: nil,
    priority: 24,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 434,
    title: "Connect Marketing Platform via OAuth",
    description: "As a client user, I want to connect my marketing platforms (Google Ads, Facebook Ads, Google Analytics) so that my marketing data can be automatically synced into the reporting system.",
    status: nil,
    priority: 6,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 435,
    title: "Connect Financial Platform via OAuth",
    description: "As a client user, I want to connect my QuickBooks account so that my revenue data can be correlated with marketing metrics.",
    status: nil,
    priority: 26,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 436,
    title: "View and Manage Platform Integrations",
    description: "As a client user, I want to view all my connected platforms so that I can manage my integrations and understand what data is being synced.",
    status: nil,
    priority: 7,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 437,
    title: "Automated Daily Data Sync",
    description: "As a system, I want to automatically sync data from all connected platforms daily so that user data stays fresh without manual intervention.",
    status: nil,
    priority: 11,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 438,
    title: "Manual Sync Trigger (Admin)",
    description: "As an admin user, I want to manually trigger a data sync so that I can debug integration issues or get fresh data on demand.",
    status: nil,
    priority: 8,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 439,
    title: "Sync Status and History",
    description: "As an admin user, I want to view sync history and status for each integration so that I can diagnose issues and understand data freshness.",
    status: nil,
    priority: 12,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 440,
    title: "Handle Expired or Invalid OAuth Credentials",
    description: "As a client user, I want to be notified when my platform credentials expire so that I can reconnect and resume data syncing.",
    status: nil,
    priority: 30,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 441,
    title: "View All Metrics Dashboard",
    description: "As a client user, I want to see all my metrics from all platforms in one unified view so that I can understand my complete marketing and financial picture.",
    status: nil,
    priority: 13,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 442,
    title: "Flexible Chart Visualization Options",
    description: "As a client user, I want to view my data using different chart types so that I can visualize information in the way that makes most sense to me.",
    status: nil,
    priority: 29,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 443,
    title: "Create and Save Custom Reports",
    description: "As a client user, I want to create and save custom reports so that I can track specific metrics important to my business.",
    status: nil,
    priority: 27,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 444,
    title: "Default Canned Dashboards",
    description: "As a client user, I want to access pre-built dashboard templates so that I can quickly get insights without building custom reports.",
    status: nil,
    priority: 28,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 445,
    title: "View and Navigate Saved Reports",
    description: "As a client user, I want to access my saved reports easily so that I can review important metrics regularly.",
    status: nil,
    priority: 35,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 446,
    title: "Select Goal Metrics for Correlation",
    description: "As a client user, I want to specify which metrics are my business goals so that the system can identify what drives those outcomes.",
    status: nil,
    priority: 32,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 447,
    title: "Automated Correlation Analysis",
    description: "As a client user, I want to see which marketing metrics correlate most with my goal metrics so that I can focus on activities that drive business results.",
    status: nil,
    priority: 17,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 448,
    title: "View Correlation Analysis Results (Raw Mode)",
    description: "As a client user, I want to view raw correlation analysis results so that I can analyze data myself without AI suggestions.",
    status: nil,
    priority: 33,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 449,
    title: "View Correlation Analysis Results (Smart/AI Mode)",
    description: "As a client user, I want to see AI-curated correlation insights so that I can quickly understand what matters most without analyzing raw data.",
    status: nil,
    priority: 34,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 450,
    title: "AI Insights and Suggestions",
    description: "As a client user, I want to get AI-powered suggestions based on my correlation data so that I can make informed decisions about where to invest.",
    status: nil,
    priority: 19,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 451,
    title: "AI Chat for Data Exploration",
    description: "As a client user, I want to chat with AI about my data so that I can ask questions and get insights in natural language.",
    status: nil,
    priority: 20,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 452,
    title: "LLM-Generated Custom Reports",
    description: "As a client user, I want to describe a report in natural language and have it generated automatically so that I can create custom visualizations without learning Vega-Lite syntax.",
    status: nil,
    priority: 31,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 453,
    title: "Agency White-label Configuration",
    description: "As an agency account owner, I want to configure white-label branding for my agency so that clients see my brand when accessing reports.",
    status: nil,
    priority: 18,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 454,
    title: "Client Views White-labeled Interface",
    description: "As a client user, I want to see my agency branding when they have originated my account so that the experience feels professional and cohesive.",
    status: nil,
    priority: 16,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 455,
    title: "Account Deletion (Owner Only)",
    description: "As an account owner, I want to delete my account permanently so that I can remove all my data from the system.",
    status: nil,
    priority: 4,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 456,
    title: "Password Reset Flow",
    description: "As a user, I want to reset my password if I forget it so that I can regain access to my account.",
    status: nil,
    priority: 21,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 493,
    title: "Cross-Platform Metric Normalization and Mapping",
    description: "As a client user, I want the system to recognize that equivalent metrics from different platforms represent the same concept (e.g., a Google Ads click is the same as a Facebook Ads click), so that I can accurately compare and aggregate the same metric across platforms without manual reconciliation.",
    status: nil,
    priority: 15,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 495,
    title: "Correct Aggregation of Derived and Calculated Metrics",
    description: "As a client user, I want calculated metrics like cost-per-click or conversion rate to be aggregated correctly when viewed across time periods or platforms, so that I see mathematically accurate numbers rather than misleading averages of averages.",
    status: nil,
    priority: 14,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 373,
    title: "SMS Notification with PWA Link",
    description: "As an installer, I want to receive an SMS with a verification link when my fuel card is swiped so I can quickly verify the transaction with one tap",
    status: nil,
    priority: 1,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 374,
    title: "PWA Instant Camera Launch",
    description: "As an installer, I want the camera to open immediately when I tap the link so I can take the photo with zero friction",
    status: nil,
    priority: 2,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 375,
    title: "Location Permission Request",
    description: "As an installer, I want to be prompted for location permission so my verification includes GPS data for fraud prevention",
    status: nil,
    priority: 4,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 376,
    title: "Photo Capture with metadata",
    description: "As an installer, I want to capture a high-quality photo with full metadata so the system can verify my transaction accurately",
    status: nil,
    priority: 3,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 377,
    title: "Photo Upload with Progress",
    description: "As an installer, I want to see upload progress so I know my verification is being processed",
    status: nil,
    priority: 5,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 378,
    title: "Offline Photo Capture & Queue",
    description: "As an installer in a dead zone, I want to take the photo offline and have it upload later so I don't get flagged when I have no connectivity",
    status: nil,
    priority: 7,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 379,
    title: "OCR - Odometer Reading Extraction",
    description: "As a fraud manager, I want odometer readings automatically extracted from photos so I can verify mileage progression without manual data entry",
    status: nil,
    priority: 8,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 380,
    title: "QR Code / Vehicle ID Sticker Recognition",
    description: "As a fraud manager, I want to identify which vehicle was fueled using sticker/QR code so I can match the transaction to the correct vehicle and detect unauthorized vehicle use",
    status: nil,
    priority: 15,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 381,
    title: "Photo Timestamp Validation",
    description: "As a fraud manager, I want to verify the photo was taken at transaction time so I can detect reused or old photos being submitted fraudulently",
    status: nil,
    priority: 16,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 382,
    title: "GPS Location Correlation",
    description: "As a fraud manager, I want to verify photo location matches card swipe location so I can detect fraudulent off-site transactions",
    status: nil,
    priority: 20,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 383,
    title: "Verification Confirmation to Installer",
    description: "As an installer, I want to receive confirmation that my verification was accepted so I know the transaction is approved and I can proceed",
    status: nil,
    priority: 6,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 384,
    title: "Consecutive Violations = Card Lock",
    description: "As a fraud manager, I want to automatically lock cards after repeated violations so I can prevent ongoing fraud without manual intervention",
    status: nil,
    priority: 13,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 385,
    title: "Real-Time Pending Verification Dashboard",
    description: "As a fraud manager, I want to see all pending verifications update in real-time so I can monitor installer compliance as it happens",
    status: nil,
    priority: 14,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 386,
    title: "Flagged Transaction Review",
    description: "As a fraud manager, I want to review all yellow/red flagged transactions so I can approve or reject suspicious charges",
    status: nil,
    priority: 9,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 387,
    title: "Real-Time High-Risk Alerts",
    description: "As a fraud manager, I want to receive immediate alerts for red-flag transactions so I can respond quickly to potential fraud",
    status: nil,
    priority: 17,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 388,
    title: "Card Lock/Unlock Management",
    description: "As a fraud manager, I want to lock or unlock installer fuel cards so I can control access after fraud detection",
    status: nil,
    priority: 18,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 389,
    title: "LLM Anomaly Detection & Question Generation",
    description: "As a fraud manager, I want to automatically question installers about anomalies via SMS so I can gather context before making final flagging decisions",
    status: nil,
    priority: 21,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 390,
    title: "LLM Response Analysis",
    description: "As a fraud manager, I want the LLM to analyze installer SMS responses so I can quickly identify suspicious explanations without reading every response",
    status: nil,
    priority: 22,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 391,
    title: "Weekly Summary Report",
    description: "As a fraud manager, I want to receive weekly summary reports so I can track overall fraud prevention effectiveness and communicate results to leadership",
    status: nil,
    priority: 25,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 392,
    title: "Audit Trail Export",
    description: "As a fraud manager, I want to export complete audit trails so I can provide documentation for investigations and compliance reporting",
    status: nil,
    priority: 24,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 419,
    title: "Configurable Transaction Spend Limits",
    description: "As a fraud manager, I want to set a system-wide transaction limit with optional per-installer overrides so I can prevent large fraudulent purchases from being approved",
    status: nil,
    priority: 19,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 420,
    title: "LLM-Routed Approval Verification",
    description: "As a fraud manager, I want approval claims from installers to be automatically verified with the mentioned approver so I can confirm whether transactions were legitimately authorized",
    status: nil,
    priority: 23,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 475,
    title: "Card Creation & Ordering",
    description: "As a fleet manager, I want to create a fuel card in Fuelytics for a driver so they can purchase fuel, with the card automatically ordered from Stripe Issuing and its fulfillment status tracked through delivery.",
    status: nil,
    priority: 10,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 479,
    title: "Onboard New Driver",
    description: "As a fleet manager, I want to onboard a new driver into Fuelytics so they can be assigned vehicles and fuel cards and participate in the verification workflow",
    status: nil,
    priority: 0,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 480,
    title: "Update Driver Profile",
    description: "As a fleet manager, I want to update a driver's profile information so I can keep records accurate when details change (e.g., new phone number, vehicle reassignment)",
    status: nil,
    priority: 1,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 481,
    title: "Offboard / Deactivate Driver",
    description: "As a fleet manager, I want to offboard a driver from Fuelytics so that their access is revoked, their cards are locked, and they can no longer make fuel purchases when they leave the organization",
    status: nil,
    priority: 2,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 482,
    title: "Reactivate Driver",
    description: "As a fleet manager, I want to reactivate a previously deactivated driver so they can resume fuel purchases if they return to the organization or were deactivated in error",
    status: nil,
    priority: 3,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 484,
    title: "Driver List and Detail View",
    description: "As a fleet manager, I want to view a list of all drivers and drill into individual driver details so I can manage my fleet and quickly access driver-related actions",
    status: nil,
    priority: 4,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 485,
    title: "Create Organization Account",
    description: "As an internal admin, I want to create a new fleet organization account in Fuelytics so that a new customer can begin onboarding their drivers, vehicles, and fuel cards",
    status: nil,
    priority: 0,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 486,
    title: "Account Selection and Tenant Scoping",
    description: "As an admin who manages multiple fleet organizations, I want to select which account I am working in so that all actions and data are scoped to the correct organization",
    status: nil,
    priority: 1,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 487,
    title: "Organization Account Settings",
    description: "As a fleet manager, I want to view and update my organization's account settings so that company information, billing details, and preferences stay current",
    status: nil,
    priority: 2,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 488,
    title: "Suspend and Reactivate Organization Account",
    description: "As an internal admin, I want to suspend or reactivate organization accounts so I can manage customer lifecycle, handle billing issues, or respond to abuse",
    status: nil,
    priority: 3,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  }
]

for story <- stories do
  unless Repo.exists?(from s in "stories", where: s.id == ^story.id) do
    Repo.insert_all("stories", [story])
  end
end

# =============================================================================
# Criteria (Acceptance Criteria)
# =============================================================================

criteria = [
  %{
    id: 3705,
    description: "SMS sent within seconds of card swipe",
    position: nil,
    verified: false,
    story_id: 373,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3706,
    description: "SMS contains: transaction amount, location, timestamp",
    position: nil,
    verified: false,
    story_id: 373,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3707,
    description: "SMS includes PWA link: \"Verify now: https://fuel.app/v/{unique_token}\"",
    position: nil,
    verified: false,
    story_id: 373,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3708,
    description: "Link contains transaction ID and installer auth token",
    position: nil,
    verified: false,
    story_id: 373,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3709,
    description: "Link does not expire (installer can verify late)",
    position: nil,
    verified: false,
    story_id: 373,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3710,
    description: "System tracks if SMS was delivered",
    position: nil,
    verified: false,
    story_id: 373,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3711,
    description: "If no response in 6 minutes, transaction gets yellow flag",
    position: nil,
    verified: false,
    story_id: 373,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3712,
    description: "Yellow flag can be cleared if installer verifies later",
    position: nil,
    verified: false,
    story_id: 373,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3720,
    description: "Tap SMS link → PWA loads instantly (minimal/no loading screen)",
    position: nil,
    verified: false,
    story_id: 374,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3721,
    description: "PWA immediately requests camera permission if not already granted",
    position: nil,
    verified: false,
    story_id: 374,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3722,
    description: "Permission prompt: \"FuelLytics needs camera access to verify your fuel purchase\"",
    position: nil,
    verified: false,
    story_id: 374,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3723,
    description: "After permission granted, camera view opens immediately",
    position: nil,
    verified: false,
    story_id: 374,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3724,
    description: "Shows live camera preview (rear camera by default)",
    position: nil,
    verified: false,
    story_id: 374,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3725,
    description: "On-screen guide: \"Frame odometer with vehicle sticker clearly visible\"",
    position: nil,
    verified: false,
    story_id: 374,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3726,
    description: "No login required (authenticated via link token)",
    position: nil,
    verified: false,
    story_id: 374,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3727,
    description: "Works on iOS Safari and Android Chrome",
    position: nil,
    verified: false,
    story_id: 374,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3728,
    description: "Minimal UI: just camera viewfinder + capture button",
    position: nil,
    verified: false,
    story_id: 374,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3729,
    description: "After camera permission, immediately request location permission",
    position: nil,
    verified: false,
    story_id: 375,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3730,
    description: "Prompt: \"Allow location access to verify you're at the gas station?\"",
    position: nil,
    verified: false,
    story_id: 375,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3731,
    description: "If granted: capture GPS coordinates with photo",
    position: nil,
    verified: false,
    story_id: 375,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3732,
    description: "If denied: photo still uploads, but transaction gets yellow flag",
    position: nil,
    verified: false,
    story_id: 375,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3733,
    description: "Location permission remembered for future transactions (browser session)",
    position: nil,
    verified: false,
    story_id: 375,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3734,
    description: "GPS coordinates captured at time of photo and sent with upload",
    position: nil,
    verified: false,
    story_id: 375,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3735,
    description: "Capture button creates photo from camera stream",
    position: nil,
    verified: false,
    story_id: 376,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3736,
    description: "Photo saved as JPEG with original quality (no compression/preprocessing)",
    position: nil,
    verified: false,
    story_id: 376,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3737,
    description: "Full EXIF metadata preserved: timestamp, GPS (if permitted), device info",
    position: nil,
    verified: false,
    story_id: 376,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3738,
    description: "Photo at device's native camera resolution (no downscaling)",
    position: nil,
    verified: false,
    story_id: 376,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3739,
    description: "After capture, show preview screen with photo",
    position: nil,
    verified: false,
    story_id: 376,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3740,
    description: "Preview shows: \"Use Photo\" and \"Retake\" buttons",
    position: nil,
    verified: false,
    story_id: 376,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3741,
    description: "\"Retake\" returns to camera view",
    position: nil,
    verified: false,
    story_id: 376,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3742,
    description: "\"Use Photo\" proceeds to upload",
    position: nil,
    verified: false,
    story_id: 376,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3743,
    description: "Original photo uploaded as-is (no client-side processing)",
    position: nil,
    verified: false,
    story_id: 376,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3744,
    description: "\"Use Photo\" triggers upload to server",
    position: nil,
    verified: false,
    story_id: 377,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3745,
    description: "Upload includes: original photo blob (unprocessed), transaction ID, GPS coordinates, client timestamp",
    position: nil,
    verified: false,
    story_id: 377,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3746,
    description: "Shows upload progress bar",
    position: nil,
    verified: false,
    story_id: 377,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3747,
    description: "Upload via HTTPS POST to /api/verify",
    position: nil,
    verified: false,
    story_id: 377,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3748,
    description: "If upload succeeds: show success screen \"✓ Verified!\"",
    position: nil,
    verified: false,
    story_id: 377,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3749,
    description: "If upload fails: show retry option",
    position: nil,
    verified: false,
    story_id: 377,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3750,
    description: "Success screen auto-closes after 3 seconds (or user can close manually)",
    position: nil,
    verified: false,
    story_id: 377,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3751,
    description: "No client-side image processing or compression",
    position: nil,
    verified: false,
    story_id: 377,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3752,
    description: "PWA detects offline status before upload",
    position: nil,
    verified: false,
    story_id: 378,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3753,
    description: "Service worker caches PWA shell for offline use",
    position: nil,
    verified: false,
    story_id: 378,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3754,
    description: "Photo stored in IndexedDB with transaction metadata",
    position: nil,
    verified: false,
    story_id: 378,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3755,
    description: "Shows message: \"No connection. Photo saved and will upload automatically when online.\"",
    position: nil,
    verified: false,
    story_id: 378,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3756,
    description: "Background sync registers sync event",
    position: nil,
    verified: false,
    story_id: 378,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3757,
    description: "When connectivity restored, auto-uploads queued photos",
    position: nil,
    verified: false,
    story_id: 378,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3758,
    description: "Installer receives confirmation SMS when upload completes",
    position: nil,
    verified: false,
    story_id: 378,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3759,
    description: "Yellow flag timer pauses during offline period (tracked by last online timestamp)",
    position: nil,
    verified: false,
    story_id: 378,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3760,
    description: "Maximum offline queue: 5 photos (prevent abuse)",
    position: nil,
    verified: false,
    story_id: 378,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3761,
    description: "Original photos stored without processing",
    position: nil,
    verified: false,
    story_id: 378,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3683,
    description: "OCR service processes uploaded image (full quality, original)",
    position: nil,
    verified: false,
    story_id: 379,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3684,
    description: "Extracts numeric odometer reading with confidence score",
    position: nil,
    verified: false,
    story_id: 379,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3685,
    description: "Flags for manual review if OCR confidence < 70% (yellow flag)",
    position: nil,
    verified: false,
    story_id: 379,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3686,
    description: "Validates odometer reading is higher than last reading for this vehicle",
    position: nil,
    verified: false,
    story_id: 379,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3687,
    description: "Flags if odometer reading is lower/same as previous (yellow flag)",
    position: nil,
    verified: false,
    story_id: 379,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3688,
    description: "Flags if odometer jump is unrealistic (>500 miles in <3 hours) (yellow flag)",
    position: nil,
    verified: false,
    story_id: 379,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3689,
    description: "Stores OCR result and confidence score for audit trail",
    position: nil,
    verified: false,
    story_id: 379,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3762,
    description: "OCR/QR detection identifies vehicle ID from sticker in photo",
    position: nil,
    verified: false,
    story_id: 380,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3763,
    description: "If QR code present, decode vehicle ID",
    position: nil,
    verified: false,
    story_id: 380,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3764,
    description: "If text sticker, OCR extracts vehicle identifier",
    position: nil,
    verified: false,
    story_id: 380,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3765,
    description: "Validates vehicle ID matches installer's assigned vehicles",
    position: nil,
    verified: false,
    story_id: 380,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3766,
    description: "If vehicle ID doesn't match assigned vehicles = yellow flag",
    position: nil,
    verified: false,
    story_id: 380,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3767,
    description: "If vehicle ID unreadable = yellow flag + manual review required",
    position: nil,
    verified: false,
    story_id: 380,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3768,
    description: "Stores detected vehicle ID and confidence score",
    position: nil,
    verified: false,
    story_id: 380,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3769,
    description: "Extract EXIF timestamp from uploaded photo",
    position: nil,
    verified: false,
    story_id: 381,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3770,
    description: "Compare EXIF timestamp to transaction timestamp",
    position: nil,
    verified: false,
    story_id: 381,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3771,
    description: "If EXIF timestamp differs by >5 minutes = yellow flag",
    position: nil,
    verified: false,
    story_id: 381,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3772,
    description: "Also capture server-side upload timestamp",
    position: nil,
    verified: false,
    story_id: 381,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3773,
    description: "If upload timestamp differs from transaction by >10 minutes = yellow flag",
    position: nil,
    verified: false,
    story_id: 381,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3774,
    description: "Store photo hash to detect exact duplicates",
    position: nil,
    verified: false,
    story_id: 381,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3775,
    description: "Duplicate photo from previous transaction = yellow flag",
    position: nil,
    verified: false,
    story_id: 381,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3776,
    description: "Two consecutive yellow flags for timestamp issues = red flag",
    position: nil,
    verified: false,
    story_id: 381,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3713,
    description: "Extract GPS coordinates from photo EXIF data AND upload metadata",
    position: nil,
    verified: false,
    story_id: 382,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3714,
    description: "Compare to card swipe location (from processor)",
    position: nil,
    verified: false,
    story_id: 382,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3715,
    description: "Acceptable radius: 500 feet",
    position: nil,
    verified: false,
    story_id: 382,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3716,
    description: "If GPS available and distance > 500 feet = yellow flag",
    position: nil,
    verified: false,
    story_id: 382,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3717,
    description: "If no GPS data (user denied permission) = yellow flag",
    position: nil,
    verified: false,
    story_id: 382,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3718,
    description: "Display location map in fraud manager review interface showing both points",
    position: nil,
    verified: false,
    story_id: 382,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3719,
    description: "Track GPS denial rate per installer (repeated denials = pattern)",
    position: nil,
    verified: false,
    story_id: 382,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3700,
    description: "Green flag: SMS \"✓ Verified. Odometer: 45,234 mi. Vehicle: #127. Thank you!\"",
    position: nil,
    verified: false,
    story_id: 383,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3701,
    description: "Yellow flag: SMS \"⚠ Verification needs review. Manager will check shortly.\"",
    position: nil,
    verified: false,
    story_id: 383,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3702,
    description: "Red flag: SMS \"✗ CARD LOCKED. Contact fleet manager immediately.\"",
    position: nil,
    verified: false,
    story_id: 383,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3703,
    description: "Confirmation sent within 10 seconds of photo processing",
    position: nil,
    verified: false,
    story_id: 383,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3704,
    description: "If processing takes >30 seconds, send interim: \"Processing your photo...\"",
    position: nil,
    verified: false,
    story_id: 383,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3777,
    description: "System tracks consecutive yellow flags per installer",
    position: nil,
    verified: false,
    story_id: 384,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3778,
    description: "2 consecutive yellow flags = automatic red flag + card lock",
    position: nil,
    verified: false,
    story_id: 384,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3779,
    description: "Red flag triggers: card lock request to processor, SMS to installer, alert to fraud manager",
    position: nil,
    verified: false,
    story_id: 384,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3780,
    description: "\"Consecutive\" resets after a successful green verification",
    position: nil,
    verified: false,
    story_id: 384,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3781,
    description: "Fraud manager can override/unlock with required comment",
    position: nil,
    verified: false,
    story_id: 384,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3782,
    description: "Audit trail of all lock/unlock actions",
    position: nil,
    verified: false,
    story_id: 384,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3783,
    description: "Phoenix LiveView dashboard with PubSub updates",
    position: nil,
    verified: false,
    story_id: 385,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3784,
    description: "Updates in real-time (no refresh needed) when: new transaction created, installer clicks verification link, photo uploaded, verification processed (green/yellow/red), timeout occurs",
    position: nil,
    verified: false,
    story_id: 385,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3785,
    description: "Shows: installer name, vehicle, transaction amount, time since transaction, countdown timer",
    position: nil,
    verified: false,
    story_id: 385,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3786,
    description: "Color-coded by status: pending (blue), green, yellow, red",
    position: nil,
    verified: false,
    story_id: 385,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3787,
    description: "Click transaction to see details: photo, OCR results, flags, EXIF data, GPS map",
    position: nil,
    verified: false,
    story_id: 385,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3788,
    description: "Filter by: date range, installer, vehicle, status",
    position: nil,
    verified: false,
    story_id: 385,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3789,
    description: "Shows count of pending/flagged transactions (live updates)",
    position: nil,
    verified: false,
    story_id: 385,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3790,
    description: "Shows link click status (clicked/not clicked)",
    position: nil,
    verified: false,
    story_id: 385,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3791,
    description: "List view of all flagged transactions (real-time updates via PubSub)",
    position: nil,
    verified: false,
    story_id: 386,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3792,
    description: "Shows: flags triggered, photo thumbnail (click to enlarge), OCR results, EXIF metadata",
    position: nil,
    verified: false,
    story_id: 386,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3793,
    description: "Display odometer reading and vehicle ID detected",
    position: nil,
    verified: false,
    story_id: 386,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3794,
    description: "Show EXIF metadata panel: timestamp, GPS coords, device info",
    position: nil,
    verified: false,
    story_id: 386,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3795,
    description: "Display GPS map if coordinates available (showing transaction location vs photo location)",
    position: nil,
    verified: false,
    story_id: 386,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3796,
    description: "Fraud manager can: approve (override to green), escalate (keep yellow), reject (red + lock card)",
    position: nil,
    verified: false,
    story_id: 386,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3797,
    description: "Comments field for fraud manager notes",
    position: nil,
    verified: false,
    story_id: 386,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3798,
    description: "Audit trail of all fraud manager actions with timestamps",
    position: nil,
    verified: false,
    story_id: 386,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3799,
    description: "SMS notification sent to installer on final decision",
    position: nil,
    verified: false,
    story_id: 386,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3800,
    description: "Real-time updates when new flags appear",
    position: nil,
    verified: false,
    story_id: 386,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3801,
    description: "SMS + Email sent immediately on red flag",
    position: nil,
    verified: false,
    story_id: 387,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3802,
    description: "Alert includes: installer, vehicle, amount, flags triggered",
    position: nil,
    verified: false,
    story_id: 387,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3803,
    description: "Link to review transaction in web dashboard",
    position: nil,
    verified: false,
    story_id: 387,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3804,
    description: "Fraud manager can respond via SMS: \"LOCK\" to disable card, \"VIEW\" to open dashboard",
    position: nil,
    verified: false,
    story_id: 387,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3805,
    description: "Alert log shows all sent notifications with timestamps",
    position: nil,
    verified: false,
    story_id: 387,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3806,
    description: "Configurable alert thresholds",
    position: nil,
    verified: false,
    story_id: 387,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3807,
    description: "Dashboard shows real-time banner when red flags occur",
    position: nil,
    verified: false,
    story_id: 387,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3808,
    description: "Lock card from transaction review screen",
    position: nil,
    verified: false,
    story_id: 388,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3809,
    description: "Lock card from installer management screen",
    position: nil,
    verified: false,
    story_id: 388,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3810,
    description: "Lock card via SMS response to alert",
    position: nil,
    verified: false,
    story_id: 388,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3811,
    description: "System sends lock request to card processor API",
    position: nil,
    verified: false,
    story_id: 388,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3812,
    description: "Installer receives SMS notification of lock with reason",
    position: nil,
    verified: false,
    story_id: 388,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3813,
    description: "Fraud manager can unlock from dashboard with required comment",
    position: nil,
    verified: false,
    story_id: 388,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3814,
    description: "Unlock requires fraud manager to review all flagged transactions first",
    position: nil,
    verified: false,
    story_id: 388,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3815,
    description: "Audit trail of all lock/unlock actions with fraud manager ID and timestamp",
    position: nil,
    verified: false,
    story_id: 388,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3816,
    description: "Dashboard updates lock status in real-time (PubSub)",
    position: nil,
    verified: false,
    story_id: 388,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3690,
    description: "LLM analyzes transaction after initial OCR/validation",
    position: nil,
    verified: false,
    story_id: 389,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3691,
    description: "Triggers on anomalies: location mismatch, timing issues, amount outliers, odometer inconsistencies",
    position: nil,
    verified: false,
    story_id: 389,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3692,
    description: "Uses standard boilerplate questions for configured scenarios",
    position: nil,
    verified: false,
    story_id: 389,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3693,
    description: "LLM generates custom questions for unconfigured anomalies",
    position: nil,
    verified: false,
    story_id: 389,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3694,
    description: "Questions sent via SMS before final flag determination",
    position: nil,
    verified: false,
    story_id: 389,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3695,
    description: "Installer responds via SMS (freeform text)",
    position: nil,
    verified: false,
    story_id: 389,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3696,
    description: "Example: \"Your last fill-up was 2 hours ago, 45 miles away. Please explain.\"",
    position: nil,
    verified: false,
    story_id: 389,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3697,
    description: "Example: \"Photo missing location data. Can you confirm you were at Shell on Main St?\"",
    position: nil,
    verified: false,
    story_id: 389,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3698,
    description: "Example: \"Odometer shows 250 miles since last fill-up (2 hours ago). Please explain.\"",
    position: nil,
    verified: false,
    story_id: 389,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3699,
    description: "Auto-flags transaction if no response within 5 minutes",
    position: nil,
    verified: false,
    story_id: 389,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3817,
    description: "LLM analyzes installer's text response",
    position: nil,
    verified: false,
    story_id: 390,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3818,
    description: "Scores response: credible (green), questionable (yellow), suspicious (red)",
    position: nil,
    verified: false,
    story_id: 390,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3819,
    description: "Extracts key facts from response",
    position: nil,
    verified: false,
    story_id: 390,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3820,
    description: "If credible: auto-approves with confidence score, fraud manager notified",
    position: nil,
    verified: false,
    story_id: 390,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3821,
    description: "If questionable: sends to fraud manager for review with LLM analysis",
    position: nil,
    verified: false,
    story_id: 390,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3822,
    description: "If suspicious: auto-flags yellow, requires fraud manager approval",
    position: nil,
    verified: false,
    story_id: 390,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3823,
    description: "Fraud manager sees LLM reasoning alongside raw response in dashboard",
    position: nil,
    verified: false,
    story_id: 390,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3824,
    description: "LLM includes confidence score and explanation for its assessment",
    position: nil,
    verified: false,
    story_id: 390,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3825,
    description: "Audit trail of LLM decisions for system improvement",
    position: nil,
    verified: false,
    story_id: 390,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3826,
    description: "Dashboard updates in real-time when LLM analysis completes",
    position: nil,
    verified: false,
    story_id: 390,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3827,
    description: "Auto-generated every Monday morning",
    position: nil,
    verified: false,
    story_id: 391,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3828,
    description: "Includes: total transactions, green/yellow/red counts, top flagged installers",
    position: nil,
    verified: false,
    story_id: 391,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3829,
    description: "Average verification time (link click to upload complete)",
    position: nil,
    verified: false,
    story_id: 391,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3830,
    description: "GPS permission grant rate",
    position: nil,
    verified: false,
    story_id: 391,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3831,
    description: "Fraud detection rate and cost savings estimates",
    position: nil,
    verified: false,
    story_id: 391,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3832,
    description: "Charts showing trends over time",
    position: nil,
    verified: false,
    story_id: 391,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3833,
    description: "Delivered via email as PDF",
    position: nil,
    verified: false,
    story_id: 391,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3834,
    description: "Accessible in dashboard archive",
    position: nil,
    verified: false,
    story_id: 391,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3835,
    description: "Export date range of transactions",
    position: nil,
    verified: false,
    story_id: 392,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3836,
    description: "Includes: photos, OCR results, full EXIF metadata, flags, fraud manager actions, timestamps",
    position: nil,
    verified: false,
    story_id: 392,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3837,
    description: "Export formats: CSV (metadata), ZIP (photos + CSV)",
    position: nil,
    verified: false,
    story_id: 392,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3838,
    description: "Filterable by installer, vehicle, status",
    position: nil,
    verified: false,
    story_id: 392,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3839,
    description: "Downloadable from dashboard",
    position: nil,
    verified: false,
    story_id: 392,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3840,
    description: "EXIF metadata exported as JSON per photo",
    position: nil,
    verified: false,
    story_id: 392,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3841,
    description: "Includes LLM analysis if applicable",
    position: nil,
    verified: false,
    story_id: 392,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3882,
    description: "Fraud manager can configure system-wide default transaction limit",
    position: nil,
    verified: false,
    story_id: 419,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3883,
    description: "Fraud manager can override system default with per-installer custom limit",
    position: nil,
    verified: false,
    story_id: 419,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3884,
    description: "If installer has custom limit, that takes precedence over system default",
    position: nil,
    verified: false,
    story_id: 419,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3885,
    description: "When transaction exceeds applicable limit, card processor automatically declines transaction",
    position: nil,
    verified: false,
    story_id: 419,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3886,
    description: "Declined transaction logged with reason: 'Exceeded spend limit ($X)'",
    position: nil,
    verified: false,
    story_id: 419,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3887,
    description: "Fraud manager receives real-time alert when transaction is declined due to limit",
    position: nil,
    verified: false,
    story_id: 419,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3888,
    description: "Installer receives SMS: 'Transaction declined - exceeds your $X limit. Contact manager if needed.'",
    position: nil,
    verified: false,
    story_id: 419,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3889,
    description: "Fraud manager can view transaction attempt history including declined transactions",
    position: nil,
    verified: false,
    story_id: 419,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3890,
    description: "Dashboard shows which installers have custom limits vs. system default",
    position: nil,
    verified: false,
    story_id: 419,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3891,
    description: "Audit trail of all limit changes with fraud manager ID and timestamp",
    position: nil,
    verified: false,
    story_id: 419,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3902,
    description: "When installer responds to anomaly question mentioning approval from specific person (e.g., 'Bob approved this'), LLM detects the claim",
    position: nil,
    verified: false,
    story_id: 420,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3903,
    description: "LLM extracts approver name/role from installer's response",
    position: nil,
    verified: false,
    story_id: 420,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3904,
    description: "System identifies the mentioned approver in the user database",
    position: nil,
    verified: false,
    story_id: 420,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3905,
    description: "Approval request automatically routed to the mentioned approver via SMS/push notification",
    position: nil,
    verified: false,
    story_id: 420,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3906,
    description: "Approver receives message: 'Did you approve [installer]'s $X transaction at [location]? Reply YES or NO'",
    position: nil,
    verified: false,
    story_id: 420,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3907,
    description: "Approver's response (YES/NO) logged with timestamp",
    position: nil,
    verified: false,
    story_id: 420,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3908,
    description: "If approver confirms (YES): transaction approved, installer and fraud manager notified",
    position: nil,
    verified: false,
    story_id: 420,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3909,
    description: "If approver denies (NO): transaction flagged red, card locked, fraud manager alerted",
    position: nil,
    verified: false,
    story_id: 420,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3910,
    description: "If no response from approver within 10 minutes: escalated to fraud manager for manual review",
    position: nil,
    verified: false,
    story_id: 420,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3911,
    description: "Audit trail shows: installer claim, approver identity, approver response, timestamps",
    position: nil,
    verified: false,
    story_id: 420,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3941,
    description: "User can register with email and password",
    position: nil,
    verified: false,
    story_id: 424,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3942,
    description: "Email verification is required before account activation",
    position: nil,
    verified: false,
    story_id: 424,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3943,
    description: "User is prompted to create an account name during registration",
    position: nil,
    verified: false,
    story_id: 424,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3944,
    description: "Account type is specified during registration (Client or Agency)",
    position: nil,
    verified: false,
    story_id: 424,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3945,
    description: "User who creates the account becomes the originator and default owner",
    position: nil,
    verified: false,
    story_id: 424,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3946,
    description: "After registration, user is logged in and directed to onboarding flow",
    position: nil,
    verified: false,
    story_id: 424,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3947,
    description: "Registration form validates email format and password strength",
    position: nil,
    verified: false,
    story_id: 424,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3948,
    description: "Duplicate email addresses are rejected with clear error message",
    position: nil,
    verified: false,
    story_id: 424,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3949,
    description: "User can log in with email and password",
    position: nil,
    verified: false,
    story_id: 425,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3950,
    description: "Failed login attempts show clear error messages",
    position: nil,
    verified: false,
    story_id: 425,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3951,
    description: "User session persists across browser tabs",
    position: nil,
    verified: false,
    story_id: 425,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3952,
    description: "User can log out from any page",
    position: nil,
    verified: false,
    story_id: 425,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3953,
    description: "Inactive sessions expire after a reasonable period",
    position: nil,
    verified: false,
    story_id: 425,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3954,
    description: "User can use Remember me option for extended sessions",
    position: nil,
    verified: false,
    story_id: 425,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3955,
    description: "Account owner or admin can invite users to their account via email",
    position: nil,
    verified: false,
    story_id: 426,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3956,
    description: "Each user has their own login credentials",
    position: nil,
    verified: false,
    story_id: 426,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3957,
    description: "Users can have different access levels: owner, admin, account manager, read-only",
    position: nil,
    verified: false,
    story_id: 426,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3958,
    description: "Access levels follow hierarchy: only owners can add owners, only admins can add admins, etc.",
    position: nil,
    verified: false,
    story_id: 426,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3959,
    description: "Account owner can view all users in their account with their access levels",
    position: nil,
    verified: false,
    story_id: 426,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3960,
    description: "Account owner or admin can modify user access levels",
    position: nil,
    verified: false,
    story_id: 426,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3961,
    description: "Account owner or admin can remove users from the account",
    position: nil,
    verified: false,
    story_id: 426,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3962,
    description: "All users on an account see the same data with account-level isolation",
    position: nil,
    verified: false,
    story_id: 426,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3963,
    description: "Agency can configure domain-based auto-enrollment for their email domain",
    position: nil,
    verified: false,
    story_id: 427,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3964,
    description: "Users who register with matching email domain are automatically added to agency account",
    position: nil,
    verified: false,
    story_id: 427,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3965,
    description: "Auto-enrolled users get default access level set by agency admin",
    position: nil,
    verified: false,
    story_id: 427,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3966,
    description: "Agency admin can view and manage all auto-enrolled team members",
    position: nil,
    verified: false,
    story_id: 427,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3967,
    description: "Agency admin can disable auto-enrollment if desired",
    position: nil,
    verified: false,
    story_id: 427,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3968,
    description: "Team members automatically inherit access to all client accounts the agency manages",
    position: nil,
    verified: false,
    story_id: 427,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3969,
    description: "Client can send email invitation to any email address (agency or individual)",
    position: nil,
    verified: false,
    story_id: 428,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3970,
    description: "Invitation email contains secure link with expiration time of 7 days",
    position: nil,
    verified: false,
    story_id: 428,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3971,
    description: "Invitee receives invitation in their email inbox",
    position: nil,
    verified: false,
    story_id: 428,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3972,
    description: "Invitation includes client account name and access level being granted",
    position: nil,
    verified: false,
    story_id: 428,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3973,
    description: "Client can specify access level in invitation: read-only, account manager, or admin",
    position: nil,
    verified: false,
    story_id: 428,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3974,
    description: "Invitation link is single-use and invalidated after acceptance or expiration",
    position: nil,
    verified: false,
    story_id: 428,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3975,
    description: "Client can view pending invitations and cancel them before acceptance",
    position: nil,
    verified: false,
    story_id: 428,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3976,
    description: "Client can invite multiple agencies or users with different access levels",
    position: nil,
    verified: false,
    story_id: 428,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3977,
    description: "User clicks invitation link and is taken to acceptance page",
    position: nil,
    verified: false,
    story_id: 429,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3978,
    description: "If not logged in, user is prompted to log in or register",
    position: nil,
    verified: false,
    story_id: 429,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3979,
    description: "Upon acceptance, user account is granted specified access level to client account",
    position: nil,
    verified: false,
    story_id: 429,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3980,
    description: "User sees client account added to their account switcher or list",
    position: nil,
    verified: false,
    story_id: 429,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3981,
    description: "Expired invitations show clear error message",
    position: nil,
    verified: false,
    story_id: 429,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3982,
    description: "Already-accepted invitations cannot be reused",
    position: nil,
    verified: false,
    story_id: 429,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3983,
    description: "If invitee is part of an agency, entire agency team gets access based on agency team structure",
    position: nil,
    verified: false,
    story_id: 429,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3984,
    description: "Client can view list of all users with access to their account",
    position: nil,
    verified: false,
    story_id: 430,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3985,
    description: "List shows user or agency name, access level, date granted, and whether they are account originator",
    position: nil,
    verified: false,
    story_id: 430,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3986,
    description: "Client can modify a user access level to upgrade or downgrade permissions",
    position: nil,
    verified: false,
    story_id: 430,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3987,
    description: "Client can revoke a user access at any time",
    position: nil,
    verified: false,
    story_id: 430,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3988,
    description: "When access is revoked, user immediately loses ability to view client data",
    position: nil,
    verified: false,
    story_id: 430,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3989,
    description: "System logs all permission changes with timestamp and user who made change",
    position: nil,
    verified: false,
    story_id: 430,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3990,
    description: "Account originator cannot have their access revoked, only ownership can be transferred",
    position: nil,
    verified: false,
    story_id: 430,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3991,
    description: "Agency sees list of all client accounts they have access to",
    position: nil,
    verified: false,
    story_id: 431,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3992,
    description: "Each client listing shows access level and origination status",
    position: nil,
    verified: false,
    story_id: 431,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3993,
    description: "Agency can switch between client accounts via account switcher",
    position: nil,
    verified: false,
    story_id: 431,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3994,
    description: "Current client context is clearly displayed in navigation",
    position: nil,
    verified: false,
    story_id: 431,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3995,
    description: "Agency with read-only access can only view reports and dashboards",
    position: nil,
    verified: false,
    story_id: 431,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3996,
    description: "Agency with account manager access can modify reports and integrations but not delete account or manage users",
    position: nil,
    verified: false,
    story_id: 431,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3997,
    description: "Agency with admin access can do everything except delete the account",
    position: nil,
    verified: false,
    story_id: 431,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3998,
    description: "Agency cannot see other users who have access to the client account unless they have admin access",
    position: nil,
    verified: false,
    story_id: 431,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3999,
    description: "If agency originated the client account, they see Originator badge",
    position: nil,
    verified: false,
    story_id: 431,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4000,
    description: "User can revoke their own access from client account settings",
    position: nil,
    verified: false,
    story_id: 432,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4001,
    description: "Confirmation prompt warns that this action cannot be undone",
    position: nil,
    verified: false,
    story_id: 432,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4002,
    description: "After revocation, client account is removed from user account list",
    position: nil,
    verified: false,
    story_id: 432,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4003,
    description: "Client is notified via email when user revokes their own access",
    position: nil,
    verified: false,
    story_id: 432,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4004,
    description: "User cannot re-access account without new invitation from client",
    position: nil,
    verified: false,
    story_id: 432,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4005,
    description: "Account originator cannot self-revoke and must transfer ownership first",
    position: nil,
    verified: false,
    story_id: 432,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4006,
    description: "Only current account owner can initiate ownership transfer",
    position: nil,
    verified: false,
    story_id: 433,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4007,
    description: "Owner can transfer to existing user with account access or send transfer invitation to new email",
    position: nil,
    verified: false,
    story_id: 433,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4008,
    description: "Transfer requires new owner to accept via email confirmation",
    position: nil,
    verified: false,
    story_id: 433,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4009,
    description: "Transfer wizard asks: Do you want to make a copy in your own account, Do you want to remain as admin after transfer",
    position: nil,
    verified: false,
    story_id: 433,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4010,
    description: "New owner must authenticate or verify identity before accepting",
    position: nil,
    verified: false,
    story_id: 433,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4011,
    description: "Upon acceptance, ownership transfers completely to new owner",
    position: nil,
    verified: false,
    story_id: 433,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4012,
    description: "Previous owner access level changes based on their selection during transfer",
    position: nil,
    verified: false,
    story_id: 433,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4013,
    description: "If account has originator relationship for white-label, originator status can optionally transfer too",
    position: nil,
    verified: false,
    story_id: 433,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4014,
    description: "All users are notified of ownership change",
    position: nil,
    verified: false,
    story_id: 433,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4015,
    description: "System logs ownership transfer with both parties confirmation",
    position: nil,
    verified: false,
    story_id: 433,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4016,
    description: "User can initiate OAuth flow for supported platforms: Google Ads, Facebook Ads, Google Analytics",
    position: nil,
    verified: false,
    story_id: 434,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4017,
    description: "OAuth flow opens in popup or new tab with platform authentication",
    position: nil,
    verified: false,
    story_id: 434,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4018,
    description: "After successful authentication, user is redirected back to platform selection",
    position: nil,
    verified: false,
    story_id: 434,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4019,
    description: "User can select which ad accounts or properties to sync from connected platform",
    position: nil,
    verified: false,
    story_id: 434,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4020,
    description: "User can modify selected accounts later without re-authenticating",
    position: nil,
    verified: false,
    story_id: 434,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4021,
    description: "Integration is saved only after successful OAuth completion",
    position: nil,
    verified: false,
    story_id: 434,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4022,
    description: "User sees confirmation that integration is active and ready to sync",
    position: nil,
    verified: false,
    story_id: 434,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4023,
    description: "Failed OAuth attempts show clear error messages",
    position: nil,
    verified: false,
    story_id: 434,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4024,
    description: "Platform connection belongs to client account and is not transferable to agency",
    position: nil,
    verified: false,
    story_id: 434,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4025,
    description: "User can initiate OAuth flow for QuickBooks",
    position: nil,
    verified: false,
    story_id: 435,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4026,
    description: "OAuth flow authenticates user and grants access to financial data",
    position: nil,
    verified: false,
    story_id: 435,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4027,
    description: "After successful authentication, user can select which income accounts to track",
    position: nil,
    verified: false,
    story_id: 435,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4028,
    description: "User can select multiple income accounts, system will sum debits and credits",
    position: nil,
    verified: false,
    story_id: 435,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4029,
    description: "Integration is saved only after successful OAuth completion",
    position: nil,
    verified: false,
    story_id: 435,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4030,
    description: "User sees confirmation that QuickBooks is connected and ready to sync",
    position: nil,
    verified: false,
    story_id: 435,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4031,
    description: "Failed OAuth attempts show clear error messages",
    position: nil,
    verified: false,
    story_id: 435,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4032,
    description: "Financial data (debits and credits) becomes just another metric in the system for correlation",
    position: nil,
    verified: false,
    story_id: 435,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4033,
    description: "User can view list of all connected integrations (marketing and financial)",
    position: nil,
    verified: false,
    story_id: 436,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4034,
    description: "Each integration shows platform name, connected date, and sync status",
    position: nil,
    verified: false,
    story_id: 436,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4035,
    description: "User can see which ad accounts, properties, or income accounts are selected for each integration",
    position: nil,
    verified: false,
    story_id: 436,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4036,
    description: "User can modify selected accounts without re-authenticating",
    position: nil,
    verified: false,
    story_id: 436,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4037,
    description: "User can disconnect or remove an integration",
    position: nil,
    verified: false,
    story_id: 436,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4038,
    description: "Disconnecting shows warning that historical data will remain but no new data will sync",
    position: nil,
    verified: false,
    story_id: 436,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4039,
    description: "User can reconnect a previously disconnected platform",
    position: nil,
    verified: false,
    story_id: 436,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4040,
    description: "All integrations treated uniformly with no special QuickBooks UI",
    position: nil,
    verified: false,
    story_id: 436,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4041,
    description: "System runs daily sync job at scheduled time (e.g., 2 AM UTC)",
    position: nil,
    verified: false,
    story_id: 437,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4042,
    description: "Sync pulls new data from all active integrations for all accounts",
    position: nil,
    verified: false,
    story_id: 437,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4043,
    description: "On first sync after connection, system backfills all available historical data from platform",
    position: nil,
    verified: false,
    story_id: 437,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4044,
    description: "Financial data (debits and credits) is stored as metrics alongside marketing metrics",
    position: nil,
    verified: false,
    story_id: 437,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4045,
    description: "Sync retrieves metrics, review data, and financial data for each day",
    position: nil,
    verified: false,
    story_id: 437,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4046,
    description: "OAuth tokens are automatically refreshed when needed",
    position: nil,
    verified: false,
    story_id: 437,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4047,
    description: "Failed syncs are automatically retried up to 3 times with exponential backoff",
    position: nil,
    verified: false,
    story_id: 437,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4048,
    description: "Sync errors are logged with details for debugging",
    position: nil,
    verified: false,
    story_id: 437,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4049,
    description: "Default date ranges exclude today to avoid showing zero for incomplete day",
    position: nil,
    verified: false,
    story_id: 437,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4050,
    description: "Admin users see Sync Now button in integration settings",
    position: nil,
    verified: false,
    story_id: 438,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4051,
    description: "Clicking sync triggers immediate data pull for that integration",
    position: nil,
    verified: false,
    story_id: 438,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4052,
    description: "UI shows sync in progress with loading indicator",
    position: nil,
    verified: false,
    story_id: 438,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4053,
    description: "Upon completion, user sees success message with timestamp and records synced",
    position: nil,
    verified: false,
    story_id: 438,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4054,
    description: "If sync fails, error details are displayed",
    position: nil,
    verified: false,
    story_id: 438,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4055,
    description: "Manual sync does not interfere with automated daily sync schedule",
    position: nil,
    verified: false,
    story_id: 438,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4056,
    description: "Each integration shows last successful sync timestamp",
    position: nil,
    verified: false,
    story_id: 439,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4057,
    description: "Each integration shows next scheduled sync time",
    position: nil,
    verified: false,
    story_id: 439,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4058,
    description: "User can view detailed sync history (last 30 syncs minimum)",
    position: nil,
    verified: false,
    story_id: 439,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4059,
    description: "Sync history shows: timestamp, status (success or failure), records synced, and any error messages",
    position: nil,
    verified: false,
    story_id: 439,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4060,
    description: "Failed syncs are highlighted with error details",
    position: nil,
    verified: false,
    story_id: 439,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4061,
    description: "User can filter sync history by status (all, success, failed)",
    position: nil,
    verified: false,
    story_id: 439,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4062,
    description: "When OAuth token refresh fails, integration status changes to Needs Reconnection",
    position: nil,
    verified: false,
    story_id: 440,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4063,
    description: "User sees warning indicator on integration in dashboard",
    position: nil,
    verified: false,
    story_id: 440,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4064,
    description: "User receives email notification about expired credentials",
    position: nil,
    verified: false,
    story_id: 440,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4065,
    description: "User can click Reconnect button to re-initiate OAuth flow",
    position: nil,
    verified: false,
    story_id: 440,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4066,
    description: "After successful reconnection, sync resumes automatically",
    position: nil,
    verified: false,
    story_id: 440,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4067,
    description: "System does not delete historical data when credentials expire",
    position: nil,
    verified: false,
    story_id: 440,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4068,
    description: "User can access All Metrics dashboard showing data from all connected platforms",
    position: nil,
    verified: false,
    story_id: 441,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4069,
    description: "Dashboard displays both marketing metrics and financial metrics with no distinction",
    position: nil,
    verified: false,
    story_id: 441,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4070,
    description: "User can filter by platform, date range, or metric type",
    position: nil,
    verified: false,
    story_id: 441,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4071,
    description: "User can select date range: last 7 days, 30 days, 90 days, all time, custom",
    position: nil,
    verified: false,
    story_id: 441,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4072,
    description: "Date ranges default to last X days from yesterday to avoid incomplete current day",
    position: nil,
    verified: false,
    story_id: 441,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4073,
    description: "Dashboard updates dynamically when filters change",
    position: nil,
    verified: false,
    story_id: 441,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4074,
    description: "If no integrations connected, dashboard shows onboarding prompts",
    position: nil,
    verified: false,
    story_id: 441,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4075,
    description: "All visualizations use Vega-Lite",
    position: nil,
    verified: false,
    story_id: 441,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4076,
    description: "User can select from multiple chart types: line, bar, donut, Gantt, scatter, area, etc.",
    position: nil,
    verified: false,
    story_id: 442,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4077,
    description: "User can switch chart types for any metric without losing filters or selections",
    position: nil,
    verified: false,
    story_id: 442,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4078,
    description: "All charts render using Vega-Lite specifications",
    position: nil,
    verified: false,
    story_id: 442,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4079,
    description: "Charts are interactive (hover for details, click to drill down where applicable)",
    position: nil,
    verified: false,
    story_id: 442,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4080,
    description: "User can add multiple charts to same view for comparison",
    position: nil,
    verified: false,
    story_id: 442,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4081,
    description: "Chart settings are saved with report when user saves",
    position: nil,
    verified: false,
    story_id: 442,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4082,
    description: "User can create new report from template or blank canvas",
    position: nil,
    verified: false,
    story_id: 443,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4083,
    description: "User can add visualizations by selecting metrics and chart types",
    position: nil,
    verified: false,
    story_id: 443,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4084,
    description: "User can arrange visualizations in layout (drag and drop or grid)",
    position: nil,
    verified: false,
    story_id: 443,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4085,
    description: "User can name and save report",
    position: nil,
    verified: false,
    story_id: 443,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4086,
    description: "Saved reports appear in user report list",
    position: nil,
    verified: false,
    story_id: 443,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4087,
    description: "User can edit saved reports",
    position: nil,
    verified: false,
    story_id: 443,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4088,
    description: "User can delete saved reports",
    position: nil,
    verified: false,
    story_id: 443,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4089,
    description: "Reports can include metrics from any connected platform (marketing and financial)",
    position: nil,
    verified: false,
    story_id: 443,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4090,
    description: "System provides default dashboard templates (e.g., Marketing Overview, Revenue Analysis, Platform Comparison)",
    position: nil,
    verified: false,
    story_id: 444,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4091,
    description: "User can select template and it auto-populates with their data",
    position: nil,
    verified: false,
    story_id: 444,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4092,
    description: "User can customize canned dashboards and save as their own",
    position: nil,
    verified: false,
    story_id: 444,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4093,
    description: "Canned dashboards update automatically as new data syncs",
    position: nil,
    verified: false,
    story_id: 444,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4094,
    description: "User can reset to default template if they have customized",
    position: nil,
    verified: false,
    story_id: 444,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4095,
    description: "User can view list of all saved reports",
    position: nil,
    verified: false,
    story_id: 445,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4096,
    description: "Reports are sorted by last modified date",
    position: nil,
    verified: false,
    story_id: 445,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4097,
    description: "User can search reports by name",
    position: nil,
    verified: false,
    story_id: 445,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4098,
    description: "Clicking report opens it in full view",
    position: nil,
    verified: false,
    story_id: 445,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4099,
    description: "Report maintains selected date range from last viewing",
    position: nil,
    verified: false,
    story_id: 445,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4100,
    description: "User can set report as favorite for quick access",
    position: nil,
    verified: false,
    story_id: 445,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4101,
    description: "User can duplicate reports to create variations",
    position: nil,
    verified: false,
    story_id: 445,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4102,
    description: "User can access Goal Metrics configuration from menu",
    position: nil,
    verified: false,
    story_id: 446,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4103,
    description: "User can select one or more metrics as goals (e.g., revenue account from QuickBooks)",
    position: nil,
    verified: false,
    story_id: 446,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4104,
    description: "Selected goal metrics are highlighted or badged in metric lists",
    position: nil,
    verified: false,
    story_id: 446,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4105,
    description: "User can modify goal metrics at any time",
    position: nil,
    verified: false,
    story_id: 446,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4106,
    description: "System stores goal metrics per account",
    position: nil,
    verified: false,
    story_id: 446,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4107,
    description: "When user selects goal metrics, system queues correlation analysis",
    position: nil,
    verified: false,
    story_id: 446,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4108,
    description: "System automatically calculates correlations between all metrics and selected goal metric(s)",
    position: nil,
    verified: false,
    story_id: 447,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4109,
    description: "Correlations are calculated daily after data sync completes",
    position: nil,
    verified: false,
    story_id: 447,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4110,
    description: "System tests multiple time lags (0-30 days) for each metric to automatically find optimal lag",
    position: nil,
    verified: false,
    story_id: 447,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4111,
    description: "System selects lag with highest absolute correlation value for each metric",
    position: nil,
    verified: false,
    story_id: 447,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4112,
    description: "Correlation calculations use daily aggregated data",
    position: nil,
    verified: false,
    story_id: 447,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4113,
    description: "Only correlations meeting minimum data threshold are calculated (e.g., 30+ days of data)",
    position: nil,
    verified: false,
    story_id: 447,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4114,
    description: "Correlation runs against ALL metrics (financial and marketing treated the same)",
    position: nil,
    verified: false,
    story_id: 447,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4115,
    description: "User can access correlation analysis from main navigation",
    position: nil,
    verified: false,
    story_id: 448,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4116,
    description: "User can toggle between Raw and Smart/AI modes",
    position: nil,
    verified: false,
    story_id: 448,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4117,
    description: "In Raw mode: analysis shows ranked list of ALL correlations (strongest to weakest)",
    position: nil,
    verified: false,
    story_id: 448,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4118,
    description: "Each correlation shows: metric name, correlation coefficient, optimal lag in days, time period analyzed",
    position: nil,
    verified: false,
    story_id: 448,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4119,
    description: "User can sort by: correlation strength, metric name, platform, lag time",
    position: nil,
    verified: false,
    story_id: 448,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4120,
    description: "User can view both positive and negative correlations",
    position: nil,
    verified: false,
    story_id: 448,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4121,
    description: "User can filter by platform or metric type",
    position: nil,
    verified: false,
    story_id: 448,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4122,
    description: "User can select different time windows for analysis (30 days, 90 days, all time)",
    position: nil,
    verified: false,
    story_id: 448,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4123,
    description: "Results update when user changes time window or filters",
    position: nil,
    verified: false,
    story_id: 448,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4124,
    description: "If insufficient data exists, user sees message explaining minimum requirements",
    position: nil,
    verified: false,
    story_id: 448,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4125,
    description: "In Smart/AI mode: analysis shows top 5 positive and top 5 negative correlations",
    position: nil,
    verified: false,
    story_id: 449,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4126,
    description: "Only correlations above minimum threshold are shown (e.g., absolute value greater than 0.3)",
    position: nil,
    verified: false,
    story_id: 449,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4127,
    description: "Results are presented with explanations (e.g., Google Ads spend shows strong correlation with revenue at 7-day lag)",
    position: nil,
    verified: false,
    story_id: 449,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4128,
    description: "AI can highlight which correlations are most meaningful based on context",
    position: nil,
    verified: false,
    story_id: 449,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4129,
    description: "User can still access full ranked list if desired",
    position: nil,
    verified: false,
    story_id: 449,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4130,
    description: "Mode selection (Raw vs Smart) is saved per user preference",
    position: nil,
    verified: false,
    story_id: 449,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4131,
    description: "User can enable AI Suggestions option in Smart mode",
    position: nil,
    verified: false,
    story_id: 450,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4132,
    description: "AI analyzes correlation data and provides actionable recommendations (e.g., Increase Google Ads budget based on 0.85 correlation with revenue)",
    position: nil,
    verified: false,
    story_id: 450,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4133,
    description: "Each chart or visualization can have an AI info button",
    position: nil,
    verified: false,
    story_id: 450,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4134,
    description: "Clicking AI button shows context-specific insights or opens chat about that metric",
    position: nil,
    verified: false,
    story_id: 450,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4135,
    description: "AI suggestions are based on correlation strength, trends, and business context",
    position: nil,
    verified: false,
    story_id: 450,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4136,
    description: "User can provide feedback on suggestions (helpful or not helpful)",
    position: nil,
    verified: false,
    story_id: 450,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4137,
    description: "AI learns from feedback to improve future suggestions",
    position: nil,
    verified: false,
    story_id: 450,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4138,
    description: "User can open AI chat from any report or visualization",
    position: nil,
    verified: false,
    story_id: 451,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4139,
    description: "Chat context includes relevant data from current view",
    position: nil,
    verified: false,
    story_id: 451,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4140,
    description: "User can ask questions like Why did my revenue drop last week",
    position: nil,
    verified: false,
    story_id: 451,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4141,
    description: "AI has access to all metrics and correlation data to answer",
    position: nil,
    verified: false,
    story_id: 451,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4142,
    description: "AI can suggest visualizations or reports based on questions",
    position: nil,
    verified: false,
    story_id: 451,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4143,
    description: "Chat history is saved per user",
    position: nil,
    verified: false,
    story_id: 451,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4144,
    description: "User can share chat insights with team members",
    position: nil,
    verified: false,
    story_id: 451,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4145,
    description: "User can enter natural language description of desired report",
    position: nil,
    verified: false,
    story_id: 452,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4146,
    description: "LLM generates valid Vega-Lite specification",
    position: nil,
    verified: false,
    story_id: 452,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4147,
    description: "User can preview generated visualization",
    position: nil,
    verified: false,
    story_id: 452,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4148,
    description: "User can provide feedback to refine the visualization",
    position: nil,
    verified: false,
    story_id: 452,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4149,
    description: "Generated report can be saved like any other custom report",
    position: nil,
    verified: false,
    story_id: 452,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4150,
    description: "User can edit Vega-Lite spec directly if desired (advanced mode)",
    position: nil,
    verified: false,
    story_id: 452,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4151,
    description: "System logs all LLM interactions for debugging",
    position: nil,
    verified: false,
    story_id: 452,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4152,
    description: "Agency can upload custom logo (supports PNG, JPG, SVG)",
    position: nil,
    verified: false,
    story_id: 453,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4153,
    description: "Agency can set custom color scheme (primary, secondary, accent colors)",
    position: nil,
    verified: false,
    story_id: 453,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4154,
    description: "Agency can configure custom subdomain (e.g., reports.andersonthefish.com)",
    position: nil,
    verified: false,
    story_id: 453,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4155,
    description: "Changes preview in real-time before saving",
    position: nil,
    verified: false,
    story_id: 453,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4156,
    description: "Agency can reset to default branding",
    position: nil,
    verified: false,
    story_id: 453,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4157,
    description: "White-label settings are stored at agency account level",
    position: nil,
    verified: false,
    story_id: 453,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4158,
    description: "Custom subdomain requires DNS verification before activation",
    position: nil,
    verified: false,
    story_id: 453,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4159,
    description: "No Anderson Analytics branding visible on white-labeled instances",
    position: nil,
    verified: false,
    story_id: 453,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4160,
    description: "When client accesses system via agency custom subdomain, they see agency branding",
    position: nil,
    verified: false,
    story_id: 454,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4161,
    description: "Agency logo appears in navigation header",
    position: nil,
    verified: false,
    story_id: 454,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4162,
    description: "Agency color scheme is applied throughout interface",
    position: nil,
    verified: false,
    story_id: 454,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4163,
    description: "When client accesses via main domain, they see default branding",
    position: nil,
    verified: false,
    story_id: 454,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4164,
    description: "If agency is account originator, white-labeling is always applied for that client",
    position: nil,
    verified: false,
    story_id: 454,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4165,
    description: "Client can still customize their own dashboards regardless of white-labeling",
    position: nil,
    verified: false,
    story_id: 454,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4166,
    description: "White-label branding does not affect functionality, only visual appearance",
    position: nil,
    verified: false,
    story_id: 454,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4167,
    description: "Only account owner role can access delete account option",
    position: nil,
    verified: false,
    story_id: 455,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4168,
    description: "Account originator cannot delete account they originated (only owner can)",
    position: nil,
    verified: false,
    story_id: 455,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4169,
    description: "Delete requires confirmation with account name typed in",
    position: nil,
    verified: false,
    story_id: 455,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4170,
    description: "Delete requires password re-entry for security",
    position: nil,
    verified: false,
    story_id: 455,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4171,
    description: "Warning explains that deletion is permanent and irreversible",
    position: nil,
    verified: false,
    story_id: 455,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4172,
    description: "Upon deletion, all account data is removed (metrics, reports, integrations)",
    position: nil,
    verified: false,
    story_id: 455,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4173,
    description: "All user access grants to this account are revoked",
    position: nil,
    verified: false,
    story_id: 455,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4174,
    description: "User receives confirmation email after deletion",
    position: nil,
    verified: false,
    story_id: 455,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4175,
    description: "Admin and other roles cannot delete account",
    position: nil,
    verified: false,
    story_id: 455,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4176,
    description: "User can request password reset from login page",
    position: nil,
    verified: false,
    story_id: 456,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4177,
    description: "User receives password reset email with secure link",
    position: nil,
    verified: false,
    story_id: 456,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4178,
    description: "Reset link expires after 24 hours",
    position: nil,
    verified: false,
    story_id: 456,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4179,
    description: "User can set new password meeting strength requirements",
    position: nil,
    verified: false,
    story_id: 456,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4180,
    description: "After successful reset, user is logged in automatically",
    position: nil,
    verified: false,
    story_id: 456,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4181,
    description: "Password reset invalidates all existing sessions",
    position: nil,
    verified: false,
    story_id: 456,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4182,
    description: "User receives confirmation email after password change",
    position: nil,
    verified: false,
    story_id: 456,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4431,
    description: "Fleet manager can initiate card creation from the driver management screen by selecting a driver and choosing 'Create Card'",
    position: nil,
    verified: false,
    story_id: 475,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4432,
    description: "Card creation form captures required details: driver assignment, spending limits, and any card-level restrictions",
    position: nil,
    verified: false,
    story_id: 475,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4433,
    description: "System validates driver eligibility (e.g., active status, no duplicate pending cards) before submitting the order",
    position: nil,
    verified: false,
    story_id: 475,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4434,
    description: "On submission, system sends a card creation request to Stripe Issuing API and stores the returned card ID",
    position: nil,
    verified: false,
    story_id: 475,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4435,
    description: "Card record is created in Fuelytics with an initial status of 'Ordered' linked to the Stripe card object",
    position: nil,
    verified: false,
    story_id: 475,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4436,
    description: "System tracks card fulfillment status lifecycle: Ordered → Shipped → Delivered → Active",
    position: nil,
    verified: false,
    story_id: 475,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4437,
    description: "System polls or receives webhooks from Stripe to automatically update card status as fulfillment progresses",
    position: nil,
    verified: false,
    story_id: 475,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4438,
    description: "Fleet manager can view current card status and estimated delivery timeline from the driver detail screen",
    position: nil,
    verified: false,
    story_id: 475,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4439,
    description: "Card list view shows all cards with their current status, assigned driver, and creation date",
    position: nil,
    verified: false,
    story_id: 475,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4440,
    description: "Fleet manager receives a notification when a card status changes (e.g., shipped, delivered)",
    position: nil,
    verified: false,
    story_id: 475,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4441,
    description: "Once card status reaches 'Delivered', fleet manager can activate the card to make it usable for transactions",
    position: nil,
    verified: false,
    story_id: 475,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4442,
    description: "Audit trail logs card creation event with requesting manager ID, driver assignment, and timestamp",
    position: nil,
    verified: false,
    story_id: 475,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4495,
    description: "Fleet manager can navigate to a 'Add Driver' action from the driver management screen",
    position: nil,
    verified: false,
    story_id: 479,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4496,
    description: "Driver creation form captures: full name, phone number (for SMS verification), email (optional), employee ID, and assigned vehicle(s)",
    position: nil,
    verified: false,
    story_id: 479,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4497,
    description: "System validates phone number format and checks for duplicates before saving",
    position: nil,
    verified: false,
    story_id: 479,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4498,
    description: "System validates employee ID is unique across the organization",
    position: nil,
    verified: false,
    story_id: 479,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4499,
    description: "Driver record is created with an 'Active' status by default",
    position: nil,
    verified: false,
    story_id: 479,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4500,
    description: "New driver's phone number is registered with the SMS notification service for future transaction verifications",
    position: nil,
    verified: false,
    story_id: 479,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4501,
    description: "Fleet manager receives confirmation that the driver was successfully onboarded",
    position: nil,
    verified: false,
    story_id: 479,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4502,
    description: "Newly onboarded driver appears in the driver list immediately",
    position: nil,
    verified: false,
    story_id: 479,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4503,
    description: "Audit trail logs driver creation event with requesting manager ID, driver details, and timestamp",
    position: nil,
    verified: false,
    story_id: 479,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4504,
    description: "Fleet manager can edit a driver's profile from the driver detail screen",
    position: nil,
    verified: false,
    story_id: 480,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4505,
    description: "Editable fields: full name, phone number, email, employee ID, assigned vehicle(s)",
    position: nil,
    verified: false,
    story_id: 480,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4506,
    description: "If phone number is changed, system updates the SMS notification service registration",
    position: nil,
    verified: false,
    story_id: 480,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4507,
    description: "If phone number is changed, system validates new number format and checks for duplicates",
    position: nil,
    verified: false,
    story_id: 480,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4508,
    description: "System prevents editing a driver who is currently in a 'Deactivated' status without first reactivating them",
    position: nil,
    verified: false,
    story_id: 480,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4509,
    description: "All changes are saved and reflected immediately in the driver list and detail views",
    position: nil,
    verified: false,
    story_id: 480,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4510,
    description: "Audit trail logs each update with: changed fields, old values, new values, manager ID, and timestamp",
    position: nil,
    verified: false,
    story_id: 480,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4511,
    description: "Fleet manager can deactivate a driver from the driver detail screen",
    position: nil,
    verified: false,
    story_id: 481,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4512,
    description: "Deactivation requires a reason (e.g., terminated, resigned, leave of absence, transferred)",
    position: nil,
    verified: false,
    story_id: 481,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4513,
    description: "System checks for active fuel cards assigned to the driver and prompts: 'This driver has X active card(s). Lock all cards?'",
    position: nil,
    verified: false,
    story_id: 481,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4514,
    description: "If confirmed, all assigned fuel cards are locked via Stripe Issuing API and card status updated to 'Locked - Driver Deactivated'",
    position: nil,
    verified: false,
    story_id: 481,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4515,
    description: "Driver status changes to 'Deactivated' and they are excluded from active driver lists and new card assignments",
    position: nil,
    verified: false,
    story_id: 481,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4516,
    description: "Driver's phone number is unregistered from SMS verification notifications",
    position: nil,
    verified: false,
    story_id: 481,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4517,
    description: "Deactivated driver's historical transaction data and audit trail remain accessible for reporting",
    position: nil,
    verified: false,
    story_id: 481,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4518,
    description: "Fleet manager receives confirmation of successful deactivation with summary of actions taken (cards locked, SMS unregistered)",
    position: nil,
    verified: false,
    story_id: 481,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4519,
    description: "Audit trail logs deactivation with: reason, manager ID, cards affected, and timestamp",
    position: nil,
    verified: false,
    story_id: 481,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4520,
    description: "Fleet manager can reactivate a previously deactivated driver from the driver detail screen",
    position: nil,
    verified: false,
    story_id: 482,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4521,
    description: "Reactivation requires a reason (e.g., rehired, returned from leave, error correction)",
    position: nil,
    verified: false,
    story_id: 482,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4522,
    description: "Upon reactivation, driver status changes to 'Active' and they reappear in active driver lists",
    position: nil,
    verified: false,
    story_id: 482,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4523,
    description: "Driver's phone number is re-registered with the SMS notification service",
    position: nil,
    verified: false,
    story_id: 482,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4524,
    description: "Previously locked cards are NOT automatically unlocked — fleet manager must manually reactivate cards individually",
    position: nil,
    verified: false,
    story_id: 482,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4525,
    description: "System displays a summary of the driver's previously assigned cards and their current statuses",
    position: nil,
    verified: false,
    story_id: 482,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4526,
    description: "Fleet manager can assign new vehicles and create new cards for the reactivated driver",
    position: nil,
    verified: false,
    story_id: 482,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4527,
    description: "Audit trail logs reactivation with: reason, manager ID, and timestamp",
    position: nil,
    verified: false,
    story_id: 482,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4535,
    description: "Fleet manager can view a paginated list of all drivers with columns: name, employee ID, status, assigned vehicles, active card count",
    position: nil,
    verified: false,
    story_id: 484,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4536,
    description: "Driver list supports filtering by status (Active, Deactivated, All)",
    position: nil,
    verified: false,
    story_id: 484,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4537,
    description: "Driver list supports search by name or employee ID",
    position: nil,
    verified: false,
    story_id: 484,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4538,
    description: "Fleet manager can click a driver to view their full detail screen",
    position: nil,
    verified: false,
    story_id: 484,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4539,
    description: "Driver detail screen shows: profile info, assigned vehicles, assigned fuel cards with statuses, and recent transaction history",
    position: nil,
    verified: false,
    story_id: 484,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4540,
    description: "Driver detail screen provides quick actions: Edit Profile, Create Card, Deactivate or Reactivate",
    position: nil,
    verified: false,
    story_id: 484,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4541,
    description: "Driver list updates in real-time when drivers are added or status changes via PubSub",
    position: nil,
    verified: false,
    story_id: 484,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4542,
    description: "Admin can create a new organization account from the internal admin panel",
    position: nil,
    verified: false,
    story_id: 485,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4543,
    description: "Account creation captures: company name, primary contact name, primary contact email, primary contact phone, and billing address",
    position: nil,
    verified: false,
    story_id: 485,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4544,
    description: "System generates a unique organization slug/ID used for tenant scoping",
    position: nil,
    verified: false,
    story_id: 485,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4545,
    description: "System creates the first fleet manager user for the organization using the primary contact details",
    position: nil,
    verified: false,
    story_id: 485,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4546,
    description: "First fleet manager receives an email invitation to set their password and log in",
    position: nil,
    verified: false,
    story_id: 485,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4547,
    description: "Account is created with a default status of Active",
    position: nil,
    verified: false,
    story_id: 485,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4548,
    description: "Admin can set initial account-level configuration: default transaction spend limit, verification timeout window",
    position: nil,
    verified: false,
    story_id: 485,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4549,
    description: "All data (drivers, vehicles, cards, transactions) is scoped to the organization tenant from creation onward",
    position: nil,
    verified: false,
    story_id: 485,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4550,
    description: "Audit trail logs account creation with: admin ID, organization details, and timestamp",
    position: nil,
    verified: false,
    story_id: 485,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4551,
    description: "Admin users who manage multiple organizations see an account selector after login",
    position: nil,
    verified: false,
    story_id: 486,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4552,
    description: "Account selector displays: organization name, status (Active/Suspended), and driver count",
    position: nil,
    verified: false,
    story_id: 486,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4553,
    description: "Selecting an account sets the active tenant context for all subsequent actions",
    position: nil,
    verified: false,
    story_id: 486,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4554,
    description: "All routes, queries, and data access are scoped to the selected organization tenant",
    position: nil,
    verified: false,
    story_id: 486,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4555,
    description: "Current active organization is clearly displayed in the navigation header at all times",
    position: nil,
    verified: false,
    story_id: 486,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4556,
    description: "Admin can switch accounts from the navigation header without logging out",
    position: nil,
    verified: false,
    story_id: 486,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4557,
    description: "If a user belongs to only one organization, account selection is skipped and they are routed directly to their dashboard",
    position: nil,
    verified: false,
    story_id: 486,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4558,
    description: "Drivers and single-org fleet managers never see the account selector and are always scoped to their organization",
    position: nil,
    verified: false,
    story_id: 486,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4559,
    description: "Unauthenticated requests and requests without an active tenant context are rejected and redirected to login or account selection",
    position: nil,
    verified: false,
    story_id: 486,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4560,
    description: "Fleet manager can access Organization Settings from the navigation menu",
    position: nil,
    verified: false,
    story_id: 487,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4561,
    description: "Settings screen displays editable fields: company name, primary contact name, primary contact email, primary contact phone, and billing address",
    position: nil,
    verified: false,
    story_id: 487,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4562,
    description: "Fleet manager can update company name and contact details and save changes",
    position: nil,
    verified: false,
    story_id: 487,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4563,
    description: "System validates email format and phone number format before saving",
    position: nil,
    verified: false,
    story_id: 487,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4564,
    description: "Billing address changes are reflected in any downstream billing integrations",
    position: nil,
    verified: false,
    story_id: 487,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4565,
    description: "Settings screen displays read-only account info: organization ID, account status, account creation date, and current plan or tier",
    position: nil,
    verified: false,
    story_id: 487,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4566,
    description: "Only users with fleet manager or admin role can access Organization Settings",
    position: nil,
    verified: false,
    story_id: 487,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4567,
    description: "All settings changes are saved and confirmed with a success notification",
    position: nil,
    verified: false,
    story_id: 487,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4568,
    description: "Audit trail logs each settings change with: changed fields, old values, new values, user ID, and timestamp",
    position: nil,
    verified: false,
    story_id: 487,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4569,
    description: "Admin can suspend an organization account from the internal admin panel",
    position: nil,
    verified: false,
    story_id: 488,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4570,
    description: "Suspending an account locks all fuel cards across the organization via Stripe Issuing API",
    position: nil,
    verified: false,
    story_id: 488,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4571,
    description: "Suspended accounts block all user logins for that organization with a message: 'Your account has been suspended. Contact support.'",
    position: nil,
    verified: false,
    story_id: 488,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4572,
    description: "No new transactions, verifications, or SMS notifications are processed for suspended accounts",
    position: nil,
    verified: false,
    story_id: 488,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4573,
    description: "Admin can reactivate a suspended account, which restores login access but does not automatically unlock cards",
    position: nil,
    verified: false,
    story_id: 488,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4574,
    description: "Admin can view a list of all organizations with filters: Active, Suspended, All",
    position: nil,
    verified: false,
    story_id: 488,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4575,
    description: "Admin can view organization details: company info, user count, driver count, card count, transaction volume",
    position: nil,
    verified: false,
    story_id: 488,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4576,
    description: "Audit trail logs all suspension and reactivation events with: admin ID, reason, and timestamp",
    position: nil,
    verified: false,
    story_id: 488,
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    account_id: uuid.("4e2e054b-df08-4a36-a9a5-a55ff60f80df"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4602,
    description: "System maintains a canonical metric taxonomy (e.g., 'clicks', 'spend', 'impressions', 'conversions') that platform-specific metrics map to",
    position: nil,
    verified: false,
    story_id: 493,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4603,
    description: "Each platform integration defines mappings from its native metric names to canonical metrics (e.g., Google Ads 'Clicks' and Facebook Ads 'Link Clicks' both map to canonical 'clicks')",
    position: nil,
    verified: false,
    story_id: 493,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4604,
    description: "When a platform metric does not have a direct equivalent in the canonical taxonomy, it is stored as a platform-specific metric and clearly labeled as such",
    position: nil,
    verified: false,
    story_id: 493,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4605,
    description: "Users can view which platform metrics are mapped to which canonical metrics",
    position: nil,
    verified: false,
    story_id: 493,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4606,
    description: "Mapped metrics can be aggregated across platforms in dashboards and reports using canonical names",
    position: nil,
    verified: false,
    story_id: 493,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4607,
    description: "Mapped metrics can be compared side-by-side across platforms (e.g., Google Ads clicks vs Facebook Ads clicks on the same chart)",
    position: nil,
    verified: false,
    story_id: 493,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4608,
    description: "Metric mappings account for known semantic differences (e.g., different attribution windows or counting methods) and surface these as warnings or footnotes when comparing",
    position: nil,
    verified: false,
    story_id: 493,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4609,
    description: "New platform integrations can define their metric mappings without requiring changes to existing canonical definitions",
    position: nil,
    verified: false,
    story_id: 493,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4610,
    description: "Derived metrics (e.g., CPC) that reference canonical component metrics automatically work across platforms once their components are mapped",
    position: nil,
    verified: false,
    story_id: 493,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4611,
    description: "System distinguishes between raw/additive metrics (e.g., clicks, spend, impressions) and derived/calculated metrics (e.g., CPC, CTR, conversion rate, ROAS)",
    position: nil,
    verified: false,
    story_id: 495,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4612,
    description: "Derived metrics are defined by a formula referencing their component raw metrics (e.g., CPC = total spend / total clicks)",
    position: nil,
    verified: false,
    story_id: 495,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4613,
    description: "When aggregating derived metrics across time periods (e.g., daily to weekly), system sums the component metrics first then calculates the derived value from the aggregated components",
    position: nil,
    verified: false,
    story_id: 495,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4614,
    description: "When aggregating derived metrics across multiple platforms or ad accounts, system sums the component metrics first then calculates the derived value from the aggregated components",
    position: nil,
    verified: false,
    story_id: 495,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4615,
    description: "System never averages a derived metric directly across rows - it always re-derives from aggregated components",
    position: nil,
    verified: false,
    story_id: 495,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4616,
    description: "Derived metric definitions are stored as metadata and can be extended for new metric types",
    position: nil,
    verified: false,
    story_id: 495,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4617,
    description: "If a component metric has missing data for a time period, the derived metric for that period reflects the gap rather than silently producing incorrect values",
    position: nil,
    verified: false,
    story_id: 495,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4618,
    description: "Derived metrics display identically to raw metrics in dashboards and reports - the aggregation logic is transparent to the user",
    position: nil,
    verified: false,
    story_id: 495,
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    account_id: uuid.("1cf53ab2-14ea-4e5f-9560-f16c1ed310fa"),
    inserted_at: now,
    updated_at: now
  }
]

for criterion <- criteria do
  unless Repo.exists?(from c in "criteria", where: c.id == ^criterion.id) do
    Repo.insert_all("criteria", [criterion])
  end
end

# =============================================================================
# Tags
# =============================================================================

tags = [
  %{
    id: 22,
    name: "domain:realtime",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 23,
    name: "epic:card-management",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 24,
    name: "epic:fraud-detection",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 25,
    name: "persona:fraud-manager",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 26,
    name: "epic:authentication",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 27,
    name: "epic:permissions",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 28,
    name: "epic:integrations",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 29,
    name: "epic:visualization",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 30,
    name: "epic:correlation",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 31,
    name: "epic:ai-features",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 32,
    name: "epic:white-label",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 33,
    name: "epic:account-management",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 34,
    name: "priority:high",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 35,
    name: "priority:medium",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 36,
    name: "priority:low",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 37,
    name: "mvp:v1",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 38,
    name: "mvp:v2",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 39,
    name: "mvp:future",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 40,
    name: "platform:google-ads",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 41,
    name: "platform:facebook-ads",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 42,
    name: "platform:google-analytics",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 43,
    name: "platform:quickbooks",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 44,
    name: "tech:vega-lite",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 45,
    name: "tech:llm",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 46,
    name: "tech:oauth",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 52,
    name: "epic:metrics",
    project_id: uuid.("5217fb4a-e2cd-493d-9e5f-2482fb8c4f2c"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 1,
    name: "notifications",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 2,
    name: "test",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 3,
    name: "driver-facing",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4,
    name: "sms",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 5,
    name: "domain:sms",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 6,
    name: "epic:verification-flow",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 7,
    name: "persona:driver",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 8,
    name: "domain:pwa",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 9,
    name: "persona:manager",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 10,
    name: "persona:system",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 11,
    name: "epic:photo-processing",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 12,
    name: "epic:fraud-detection",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 13,
    name: "epic:dashboard",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 14,
    name: "epic:card-management",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 15,
    name: "epic:reporting",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 16,
    name: "epic:llm-features",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 17,
    name: "domain:ocr",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 18,
    name: "domain:realtime",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 19,
    name: "domain:llm",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 20,
    name: "persona:fraud-manager",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 21,
    name: "persona:installer",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 47,
    name: "domain:card-issuing",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 48,
    name: "persona:fleet-manager",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 49,
    name: "epic:driver-management",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 50,
    name: "epic:account-management",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 51,
    name: "persona:admin",
    project_id: uuid.("f410b38b-2c33-41ec-9b69-532c168c1a0d"),
    inserted_at: now,
    updated_at: now
  }
]

for tag <- tags do
  unless Repo.exists?(from t in "component_tags", where: t.id == ^tag.id) do
    Repo.insert_all("component_tags", [tag])
  end
end

# =============================================================================
# Story Tags (join table)
# =============================================================================

story_tags = [
  %{
    tag_id: 5,
    story_id: 373,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 6,
    story_id: 373,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 21,
    story_id: 373,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 6,
    story_id: 374,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 8,
    story_id: 374,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 21,
    story_id: 374,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 6,
    story_id: 375,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 8,
    story_id: 375,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 21,
    story_id: 375,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 6,
    story_id: 376,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 8,
    story_id: 376,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 21,
    story_id: 376,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 6,
    story_id: 377,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 8,
    story_id: 377,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 21,
    story_id: 377,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 6,
    story_id: 378,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 8,
    story_id: 378,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 21,
    story_id: 378,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 11,
    story_id: 379,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 17,
    story_id: 379,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 20,
    story_id: 379,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 11,
    story_id: 380,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 17,
    story_id: 380,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 20,
    story_id: 380,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 11,
    story_id: 381,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 12,
    story_id: 381,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 20,
    story_id: 381,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 11,
    story_id: 382,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 12,
    story_id: 382,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 20,
    story_id: 382,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 5,
    story_id: 383,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 6,
    story_id: 383,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 21,
    story_id: 383,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 12,
    story_id: 384,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 14,
    story_id: 384,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 20,
    story_id: 384,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 13,
    story_id: 385,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 18,
    story_id: 385,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 20,
    story_id: 385,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 12,
    story_id: 386,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 13,
    story_id: 386,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 18,
    story_id: 386,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 20,
    story_id: 386,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 5,
    story_id: 387,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 12,
    story_id: 387,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 20,
    story_id: 387,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 14,
    story_id: 388,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 18,
    story_id: 388,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 20,
    story_id: 388,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 5,
    story_id: 389,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 12,
    story_id: 389,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 16,
    story_id: 389,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 19,
    story_id: 389,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 20,
    story_id: 389,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 12,
    story_id: 390,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 16,
    story_id: 390,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 18,
    story_id: 390,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 19,
    story_id: 390,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 20,
    story_id: 390,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 15,
    story_id: 391,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 20,
    story_id: 391,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 15,
    story_id: 392,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 20,
    story_id: 392,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 12,
    story_id: 419,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 14,
    story_id: 419,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 18,
    story_id: 419,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 20,
    story_id: 419,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 5,
    story_id: 420,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 12,
    story_id: 420,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 16,
    story_id: 420,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 20,
    story_id: 420,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 26,
    story_id: 424,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 34,
    story_id: 424,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 37,
    story_id: 424,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 26,
    story_id: 425,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 34,
    story_id: 425,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 37,
    story_id: 425,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 27,
    story_id: 426,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 34,
    story_id: 426,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 37,
    story_id: 426,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 27,
    story_id: 427,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 36,
    story_id: 427,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 39,
    story_id: 427,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 27,
    story_id: 428,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 35,
    story_id: 428,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 38,
    story_id: 428,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 27,
    story_id: 429,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 35,
    story_id: 429,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 38,
    story_id: 429,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 27,
    story_id: 430,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 35,
    story_id: 430,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 38,
    story_id: 430,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 27,
    story_id: 431,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 35,
    story_id: 431,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 38,
    story_id: 431,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 27,
    story_id: 432,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 36,
    story_id: 432,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 39,
    story_id: 432,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 27,
    story_id: 433,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 36,
    story_id: 433,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 39,
    story_id: 433,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 28,
    story_id: 434,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 34,
    story_id: 434,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 37,
    story_id: 434,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 40,
    story_id: 434,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 41,
    story_id: 434,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 42,
    story_id: 434,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 46,
    story_id: 434,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 28,
    story_id: 435,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 34,
    story_id: 435,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 37,
    story_id: 435,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 43,
    story_id: 435,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 46,
    story_id: 435,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 28,
    story_id: 436,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 34,
    story_id: 436,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 37,
    story_id: 436,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 46,
    story_id: 436,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 28,
    story_id: 437,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 34,
    story_id: 437,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 37,
    story_id: 437,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 28,
    story_id: 438,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 35,
    story_id: 438,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 38,
    story_id: 438,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 28,
    story_id: 439,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 35,
    story_id: 439,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 38,
    story_id: 439,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 28,
    story_id: 440,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 36,
    story_id: 440,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 46,
    story_id: 440,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 29,
    story_id: 441,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 34,
    story_id: 441,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 37,
    story_id: 441,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 29,
    story_id: 442,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 35,
    story_id: 442,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 37,
    story_id: 442,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 29,
    story_id: 443,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 35,
    story_id: 443,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 38,
    story_id: 443,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 29,
    story_id: 444,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 36,
    story_id: 444,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 38,
    story_id: 444,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 29,
    story_id: 445,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 36,
    story_id: 445,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 38,
    story_id: 445,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 30,
    story_id: 446,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 34,
    story_id: 446,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 37,
    story_id: 446,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 30,
    story_id: 447,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 34,
    story_id: 447,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 37,
    story_id: 447,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 30,
    story_id: 448,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 35,
    story_id: 448,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 37,
    story_id: 448,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 30,
    story_id: 449,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 36,
    story_id: 449,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 38,
    story_id: 449,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 31,
    story_id: 450,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 36,
    story_id: 450,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 39,
    story_id: 450,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 45,
    story_id: 450,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 31,
    story_id: 451,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 36,
    story_id: 451,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 39,
    story_id: 451,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 45,
    story_id: 451,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 31,
    story_id: 452,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 36,
    story_id: 452,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 39,
    story_id: 452,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 44,
    story_id: 452,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 45,
    story_id: 452,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 32,
    story_id: 453,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 36,
    story_id: 453,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 38,
    story_id: 453,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 32,
    story_id: 454,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 36,
    story_id: 454,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 38,
    story_id: 454,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 33,
    story_id: 455,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 36,
    story_id: 455,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 26,
    story_id: 456,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 36,
    story_id: 456,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 14,
    story_id: 475,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 47,
    story_id: 475,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 48,
    story_id: 475,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 48,
    story_id: 479,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 49,
    story_id: 479,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 48,
    story_id: 480,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 49,
    story_id: 480,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 48,
    story_id: 481,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 49,
    story_id: 481,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 48,
    story_id: 482,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 49,
    story_id: 482,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 48,
    story_id: 484,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 49,
    story_id: 484,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 50,
    story_id: 485,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 51,
    story_id: 485,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 50,
    story_id: 486,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 51,
    story_id: 486,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 48,
    story_id: 487,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 50,
    story_id: 487,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 50,
    story_id: 488,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 51,
    story_id: 488,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 34,
    story_id: 493,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 37,
    story_id: 493,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 52,
    story_id: 493,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 34,
    story_id: 495,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 37,
    story_id: 495,
    inserted_at: now,
    updated_at: now
  },
  %{
    tag_id: 52,
    story_id: 495,
    inserted_at: now,
    updated_at: now
  }
]

for story_tag <- story_tags do
  unless Repo.exists?(
           from st in "story_tags",
             where: st.tag_id == ^story_tag.tag_id and st.story_id == ^story_tag.story_id
         ) do
    Repo.insert_all("story_tags", [story_tag])
  end
end

IO.puts("""
Seeded MetricFlow and Fuelytics:
  - 2 accounts (Anderson, Fuelytics)
  - 2 projects (Metric FLow, Fuelytics Web App)
  - 67 stories
  - 525 criteria
  - 52 tags
  - 206 story_tags
""")
