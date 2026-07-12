defmodule MokaidWeb.Router do
  use Phoenix.Router, helpers: false

  import Plug.Conn
  import Phoenix.Controller

  pipeline :api do
    plug :accepts, ["json"]
    plug MokaidWeb.Plugs.RateLimiter
  end

  pipeline :authenticated do
    plug MokaidWeb.Plugs.Authenticate
  end

  pipeline :workspace do
    plug MokaidWeb.Plugs.WorkspaceScope
  end

  pipeline :worker do
    plug MokaidWeb.Plugs.WorkerAuth
  end

  scope "/api", MokaidWeb do
    pipe_through :api

    get "/health", HealthController, :show
    get "/integrations/logos/:key", IntegrationController, :logo
    get "/mcp/logos/:key", MCPController, :logo

    post "/auth/login", AuthController, :login
    post "/auth/register", AuthController, :register
    post "/auth/logout", AuthController, :logout

    # PayMe posts payment results here (reconciled by invoice id).
    post "/payme/callback", PaymeWebhookController, :callback
  end

  scope "/api", MokaidWeb do
    pipe_through [:api, :authenticated]

    get "/me", AuthController, :me
    get "/workspaces", WorkspaceController, :index
    post "/workspaces", WorkspaceController, :create

    get "/assets-3d", Asset3dController, :index
    get "/assets-3d/:id", Asset3dController, :show
  end

  scope "/api", MokaidWeb do
    pipe_through [:api, :authenticated, :workspace]

    get "/workspaces/:id", WorkspaceController, :show
    get "/workspaces/:id/logo", WorkspaceController, :logo
    patch "/workspaces/:id", WorkspaceController, :update
    post "/workspaces/:id/logo", WorkspaceController, :upload_logo
    delete "/workspaces/:id", WorkspaceController, :delete

    resources "/agents", AgentController, only: [:index, :create, :show, :update, :delete]
    post "/agents/:id/link-user", AgentController, :link_user
    post "/agents/:id/unlink-user", AgentController, :unlink_user
    post "/agents/:id/assign-task", AgentController, :assign_task
    post "/agents/:id/files", AgentController, :upload_files
    get "/agents/:id/progression", AgentController, :progression

    get "/agent-chats", AgentChatController, :index
    get "/agents/:agent_id/chat", AgentChatController, :show
    post "/agents/:agent_id/chat", AgentChatController, :create
    post "/agents/:agent_id/chat/read", AgentChatController, :mark_read
    get "/agents/:agent_id/conversations", AgentChatController, :conversations
    post "/agents/:agent_id/conversations/new", AgentChatController, :new_conversation

    post "/dispatch/analyze", DispatchController, :analyze
    post "/dispatch/confirm", DispatchController, :confirm

    resources "/tasks", TaskController, only: [:index, :create, :show, :update, :delete]
    patch "/tasks/:task_id/subtasks/:id", TaskController, :update_subtask
    post "/tasks/:id/comments", TaskController, :create_comment
    post "/tasks/:id/execute-ai", TaskController, :execute_ai
    post "/tasks/:id/stop-ai", TaskController, :stop_ai
    post "/tasks/:id/approve-action", TaskController, :approve_action

    resources "/projects", ProjectController, only: [:index, :create, :show, :update, :delete]

    resources "/knowledge", KnowledgeController, only: [:index, :create, :show, :update]
    get "/knowledge-categories", KnowledgeController, :categories
    post "/knowledge/upload", KnowledgeController, :upload

    post "/drive/upload", DriveController, :upload
    resources "/drive", DriveController, only: [:index, :create, :show, :update, :delete]
    get "/drive/:id/children", DriveController, :children
    get "/drive/:id/download", DriveController, :download
    get "/drive/:id/raw", DriveController, :raw
    post "/drive/:id/restore", DriveController, :restore
    get "/drive-trash", DriveController, :trash

    get "/calendar/events", CalendarController, :index
    post "/calendar/events", CalendarController, :create

    get "/members", MemberController, :index
    post "/members/invite", MemberController, :invite
    patch "/members/:id", MemberController, :update
    post "/members/:id/link-agent", MemberController, :link_agent

    get "/leave-requests", LeaveRequestController, :index
    post "/leave-requests", LeaveRequestController, :create
    post "/leave-requests/:id/approve", LeaveRequestController, :approve
    post "/leave-requests/:id/reject", LeaveRequestController, :reject

    get "/integrations", IntegrationController, :index
    post "/integrations/:provider/connect", IntegrationController, :connect
    post "/integrations/:id/disconnect", IntegrationController, :disconnect
    post "/integrations/google/oauth/start", IntegrationOAuthController, :google_start
    post "/integrations/google/oauth/callback", IntegrationOAuthController, :google_callback
    post "/integrations/github/oauth/start", IntegrationOAuthController, :github_start
    post "/integrations/github/oauth/callback", IntegrationOAuthController, :github_callback
    post "/integrations/linear/oauth/start", IntegrationOAuthController, :linear_start
    post "/integrations/linear/oauth/callback", IntegrationOAuthController, :linear_callback
    post "/integrations/slack/oauth/start", IntegrationOAuthController, :slack_start
    post "/integrations/slack/oauth/callback", IntegrationOAuthController, :slack_callback
    post "/integrations/notion/oauth/start", IntegrationOAuthController, :notion_start
    post "/integrations/notion/oauth/callback", IntegrationOAuthController, :notion_callback

    get "/mcp", MCPController, :index
    post "/mcp/:server/install", MCPController, :install
    delete "/mcp/installations/:id", MCPController, :uninstall
    get "/agents/:agent_id/mcp-grants", MCPController, :agent_grants
    put "/agents/:agent_id/mcp-grants/:installation_id", MCPController, :set_grant

    post "/mcp/figma/oauth/start", MCPOAuthController, :figma_start
    post "/mcp/figma/oauth/callback", MCPOAuthController, :figma_callback

    get "/billing/overview", BillingController, :overview
    get "/billing/invoices", BillingController, :invoices
    get "/billing/plans", BillingController, :plans
    get "/billing/credit-packs", BillingController, :credit_packs
    post "/billing/change-plan", BillingController, :change_plan
    post "/billing/checkout", BillingController, :checkout
    post "/billing/credits/checkout", BillingController, :credits_checkout
    post "/billing/auto-recharge", BillingController, :update_auto_recharge

    get "/analytics/overview", AnalyticsController, :overview
    get "/analytics/agents", AnalyticsController, :agents
    get "/analytics/tasks", AnalyticsController, :tasks

    get "/notifications", NotificationController, :index
    post "/notifications/:id/read", NotificationController, :mark_read

    get "/search", SearchController, :index
  end

  scope "/api/worker", MokaidWeb do
    pipe_through [:api, :worker]

    post "/runs/:run_id/progress", WorkerCallbackController, :progress
    post "/runs/:run_id/status", WorkerCallbackController, :progress
    post "/runs/:run_id/approval-request", WorkerCallbackController, :approval_request
    post "/runs/:run_id/approval", WorkerCallbackController, :approval_request
    post "/runs/:run_id/complete", WorkerCallbackController, :complete
    post "/runs/:run_id/fail", WorkerCallbackController, :fail

    post "/knowledge/search", WorkerResourceController, :search_knowledge
    post "/knowledge/:id/chunks", WorkerResourceController, :knowledge_chunks
    post "/tasks/:id/update", WorkerResourceController, :update_task
    post "/tasks/:id/subtasks", WorkerResourceController, :create_subtasks
    post "/tasks/:id/comment", WorkerResourceController, :create_comment
    post "/agents/:id/chat-message", WorkerResourceController, :agent_chat_message
    post "/agents/:id/chat-stream", WorkerResourceController, :agent_chat_stream
    post "/agents/:id/memory", WorkerResourceController, :agent_memory
    post "/tasks/:id/output", WorkerResourceController, :save_output
  end
end
