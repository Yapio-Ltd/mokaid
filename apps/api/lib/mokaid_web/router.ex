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

    post "/auth/login", AuthController, :login
    post "/auth/register", AuthController, :register
    post "/auth/logout", AuthController, :logout
  end

  scope "/api", MokaidWeb do
    pipe_through [:api, :authenticated]

    get "/me", AuthController, :me
    get "/workspaces", WorkspaceController, :index
    post "/workspaces", WorkspaceController, :create
  end

  scope "/api", MokaidWeb do
    pipe_through [:api, :authenticated, :workspace]

    get "/workspaces/:id", WorkspaceController, :show
    patch "/workspaces/:id", WorkspaceController, :update
    delete "/workspaces/:id", WorkspaceController, :delete

    resources "/agents", AgentController, only: [:index, :create, :show, :update, :delete]
    post "/agents/:id/link-user", AgentController, :link_user
    post "/agents/:id/unlink-user", AgentController, :unlink_user
    post "/agents/:id/assign-task", AgentController, :assign_task

    resources "/tasks", TaskController, only: [:index, :create, :show, :update, :delete]
    patch "/tasks/:task_id/subtasks/:id", TaskController, :update_subtask
    post "/tasks/:id/comments", TaskController, :create_comment
    post "/tasks/:id/execute-ai", TaskController, :execute_ai
    post "/tasks/:id/approve-action", TaskController, :approve_action

    resources "/projects", ProjectController, only: [:index, :create, :show, :update, :delete]

    resources "/knowledge", KnowledgeController, only: [:index, :create, :show, :update]
    get "/knowledge-categories", KnowledgeController, :categories
    post "/knowledge/upload", KnowledgeController, :upload

    post "/drive/upload", DriveController, :upload
    resources "/drive", DriveController, only: [:index, :create, :show, :update, :delete]
    get "/drive/:id/children", DriveController, :children
    get "/drive/:id/download", DriveController, :download
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
    post "/billing/change-plan", BillingController, :change_plan

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
  end
end
