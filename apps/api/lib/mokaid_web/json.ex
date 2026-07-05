defmodule MokaidWeb.JSON do
  @moduledoc "Central JSON serializers for API responses."

  def user(nil), do: nil

  def user(user) do
    %{
      id: user.id,
      email: user.email,
      full_name: user.full_name,
      avatar_url: user.avatar_url,
      locale: user.locale,
      timezone: user.timezone,
      mfa_enabled: user.mfa_enabled,
      last_login_at: user.last_login_at
    }
  end

  def workspace(workspace) do
    %{
      id: workspace.id,
      name: workspace.name,
      slug: workspace.slug,
      logo_url: workspace.logo_url,
      description: workspace.description,
      industry: workspace.industry,
      timezone: workspace.timezone,
      date_format: workspace.date_format,
      time_format: workspace.time_format,
      language: workspace.language,
      default_landing_page: workspace.default_landing_page,
      feature_toggles: workspace.feature_toggles,
      inserted_at: workspace.inserted_at
    }
  end

  def agent(agent) do
    linked_user = loaded(agent.linked_user)

    %{
      id: agent.id,
      workspace_id: agent.workspace_id,
      kind: agent.kind,
      display_name: agent.display_name,
      slug: agent.slug,
      email_alias: agent.email_alias,
      avatar_config: agent.avatar_config,
      role_title: agent.role_title,
      department: agent.department,
      status: agent.status,
      presence_status: agent.presence_status,
      control_mode: agent.control_mode,
      ai_enabled: agent.ai_enabled,
      human_takeover_enabled: agent.human_takeover_enabled,
      skills: agent.skills,
      capabilities: agent.capabilities,
      current_task_id: agent.current_task_id,
      performance_score: agent.performance_score && Decimal.to_float(agent.performance_score),
      linked_user_id: agent.linked_user_id,
      linked_member_id: agent.linked_member_id,
      linked_user_name: linked_user && linked_user.full_name,
      linked_user_email: linked_user && linked_user.email,
      last_active_at: agent.last_active_at,
      inserted_at: agent.inserted_at
    }
  end

  def task(task) do
    project = loaded(task.project)
    agent = loaded(task.assigned_agent)
    subtasks = loaded(task.subtasks) || []

    %{
      id: task.id,
      workspace_id: task.workspace_id,
      project_id: task.project_id,
      project_name: project && project.name,
      title: task.title,
      description: task.description,
      status: task.status,
      priority: task.priority,
      assigned_agent_id: task.assigned_agent_id,
      assigned_agent_name: agent && agent.display_name,
      assigned_agent_kind: agent && agent.kind,
      created_by_member_id: task.created_by_member_id,
      due_at: task.due_at,
      started_at: task.started_at,
      completed_at: task.completed_at,
      progress_percent: task.progress_percent,
      requires_approval: task.requires_approval,
      tags: task.tags,
      position: task.position,
      subtask_count: length(subtasks),
      subtask_done_count: Enum.count(subtasks, & &1.done),
      subtasks: Enum.map(subtasks, &subtask/1),
      comments: comments(loaded(task.comments)),
      inserted_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end

  def subtask(subtask) do
    %{
      id: subtask.id,
      task_id: subtask.task_id,
      title: subtask.title,
      done: subtask.done,
      position: subtask.position
    }
  end

  defp comments(nil), do: []
  defp comments(list), do: Enum.map(list, &comment/1)

  def comment(comment) do
    member = loaded(comment.author_member)
    agent = loaded(comment.author_agent)
    member_user = member && loaded(member.user)

    %{
      id: comment.id,
      task_id: comment.task_id,
      body: comment.body,
      author_kind: if(agent, do: "agent", else: "member"),
      author_name: (agent && agent.display_name) || (member_user && member_user.full_name),
      inserted_at: comment.inserted_at
    }
  end

  def project(project) do
    owner = loaded(project.owner_member)
    owner_user = owner && loaded(owner.user)
    tasks = loaded(project.tasks) || []
    project_agents = loaded(project.project_agents) || []
    project_members = loaded(project.project_members) || []

    %{
      id: project.id,
      workspace_id: project.workspace_id,
      name: project.name,
      description: project.description,
      status: project.status,
      priority: project.priority,
      progress_percent: project.progress_percent,
      owner_member_id: project.owner_member_id,
      owner_name: owner_user && owner_user.full_name,
      start_at: project.start_at,
      due_at: project.due_at,
      cover_kind: project.cover_kind,
      drive_folder_id: project.drive_folder_id,
      task_count: length(tasks),
      completed_task_count: Enum.count(tasks, &(&1.status == "completed")),
      agent_ids: Enum.map(project_agents, & &1.agent_id),
      members:
        Enum.map(project_members, fn pm ->
          member = loaded(pm.member)
          member_user = member && loaded(member.user)

          %{
            member_id: pm.member_id,
            role: pm.role,
            full_name: member_user && member_user.full_name,
            avatar_url: member_user && member_user.avatar_url
          }
        end),
      inserted_at: project.inserted_at
    }
  end

  def member(member) do
    user = loaded(member.user)
    role = loaded(member.role)
    team = loaded(member.team)
    agent = loaded(member.linked_agent)

    %{
      id: member.id,
      workspace_id: member.workspace_id,
      user_id: member.user_id,
      full_name: user && user.full_name,
      email: user && user.email,
      avatar_url: user && user.avatar_url,
      role_name: (role && role.name) || "Member",
      team_name: team && team.name,
      title: member.title,
      status: member.status,
      linked_agent_id: agent && agent.id,
      linked_agent_name: agent && agent.display_name,
      mfa_enabled: (user && user.mfa_enabled) || false,
      leave_balances: member.leave_balances,
      joined_at: member.joined_at,
      last_active_at: member.last_active_at
    }
  end

  def leave_request(request) do
    member = loaded(request.member)
    member_user = member && loaded(member.user)
    reviewer = loaded(request.reviewed_by_member)
    reviewer_user = reviewer && loaded(reviewer.user)

    %{
      id: request.id,
      workspace_id: request.workspace_id,
      member_id: request.member_id,
      member_name: member_user && member_user.full_name,
      agent_id: request.agent_id,
      type: request.type,
      status: request.status,
      start_at: request.start_at,
      end_at: request.end_at,
      reason: request.reason,
      reviewed_by_name: reviewer_user && reviewer_user.full_name,
      reviewed_at: request.reviewed_at,
      review_note: request.review_note,
      inserted_at: request.inserted_at
    }
  end

  def knowledge_item(item) do
    category = loaded(item.category)
    creator = loaded(item.created_by_member)
    creator_user = creator && loaded(creator.user)

    %{
      id: item.id,
      workspace_id: item.workspace_id,
      category_id: item.category_id,
      category_name: category && category.name,
      category_color: category && category.color,
      title: item.title,
      type: item.type,
      source_url: item.source_url,
      status: item.status,
      visibility: item.visibility,
      tags: item.tags,
      version: item.version,
      indexing_status: item.indexing_status,
      used_by_agent_ids: item.metadata["used_by_agent_ids"] || [],
      file_size_bytes: item.metadata["file_size_bytes"],
      created_by_name: creator_user && creator_user.full_name,
      updated_at: item.updated_at,
      inserted_at: item.inserted_at
    }
  end

  def knowledge_category(category) do
    items = loaded(category.items) || []

    %{
      id: category.id,
      name: category.name,
      color: category.color,
      position: category.position,
      item_count: length(items)
    }
  end

  def drive_item(item) do
    creator_member = loaded(item.created_by_member)
    creator_user = creator_member && loaded(creator_member.user)
    creator_agent = loaded(item.created_by_agent)
    versions = loaded(item.versions)

    %{
      id: item.id,
      workspace_id: item.workspace_id,
      parent_id: item.parent_id,
      kind: item.kind,
      name: item.name,
      mime_type: item.mime_type,
      extension: item.extension,
      size_bytes: item.size_bytes,
      visibility: item.visibility,
      status: item.status,
      is_ai_readable: item.is_ai_readable,
      is_system_folder: item.is_system_folder,
      tags: item.tags,
      linked_project_id: item.linked_project_id,
      linked_task_id: item.linked_task_id,
      linked_agent_id: item.linked_agent_id,
      created_by_kind: if(creator_agent, do: "agent", else: "member"),
      created_by_name:
        (creator_agent && creator_agent.display_name) || (creator_user && creator_user.full_name),
      version_count: if(is_list(versions), do: length(versions), else: 0),
      trashed_at: item.trashed_at,
      inserted_at: item.inserted_at,
      updated_at: item.updated_at
    }
  end

  def calendar_event(event) do
    member = loaded(event.member)
    member_user = member && loaded(member.user)
    agent = loaded(event.agent)
    project = loaded(event.project)
    task = loaded(event.task)

    %{
      id: event.id,
      title: event.title,
      description: event.description,
      kind: event.kind,
      start_at: event.start_at,
      end_at: event.end_at,
      all_day: event.all_day,
      member_id: event.member_id,
      member_name: member_user && member_user.full_name,
      agent_id: event.agent_id,
      agent_name: agent && agent.display_name,
      project_id: event.project_id,
      project_name: project && project.name,
      task_id: event.task_id,
      task_title: task && task.title,
      color: event.color
    }
  end

  def integration_connection(connection) do
    provider = loaded(connection.provider)

    %{
      id: connection.id,
      provider_key: provider && provider.key,
      provider_name: provider && provider.name,
      category: provider && provider.category,
      description: provider && provider.description,
      status: connection.status,
      connected_account: connection.connected_account,
      permissions: connection.permissions,
      last_sync_at: connection.last_sync_at
    }
  end

  def mcp_server(server) do
    %{
      id: server.id,
      key: server.key,
      name: server.name,
      category: server.category,
      description: server.description,
      logo_slug: server.logo_slug,
      featured: server.featured,
      auth_kind: server.auth_kind,
      transport: server.transport,
      server_url: server.server_url,
      docs_url: server.docs_url
    }
  end

  def mcp_installation(installation) do
    server = loaded(installation.server)

    %{
      id: installation.id,
      server_id: installation.server_id,
      server_key: server && server.key,
      server_name: server && server.name,
      category: server && server.category,
      logo_slug: server && server.logo_slug,
      auth_kind: server && server.auth_kind,
      status: installation.status,
      connected_account: installation.connected_account,
      settings: Map.take(installation.settings || %{}, ["server_url"]),
      error: installation.error,
      last_used_at: installation.last_used_at,
      inserted_at: installation.inserted_at
    }
  end

  def mcp_grant(grant) do
    installation = loaded(grant.installation)
    server = installation && loaded(installation.server)

    %{
      id: grant.id,
      agent_id: grant.agent_id,
      installation_id: grant.installation_id,
      granted: grant.granted,
      server_key: server && server.key,
      server_name: server && server.name,
      logo_slug: server && server.logo_slug
    }
  end

  def integration_provider(provider) do
    %{
      id: provider.id,
      key: provider.key,
      name: provider.name,
      category: provider.category,
      description: provider.description,
      auth_kind: provider.auth_kind
    }
  end

  def invoice(invoice) do
    %{
      id: invoice.id,
      number: invoice.number,
      status: invoice.status,
      amount_cents: invoice.amount_cents,
      currency: invoice.currency,
      issued_at: invoice.issued_at,
      paid_at: invoice.paid_at,
      line_items: invoice.line_items
    }
  end

  def notification(notification) do
    %{
      id: notification.id,
      kind: notification.kind,
      title: notification.title,
      body: notification.body,
      resource_type: notification.resource_type,
      resource_id: notification.resource_id,
      read_at: notification.read_at,
      inserted_at: notification.inserted_at
    }
  end

  defp loaded(%Ecto.Association.NotLoaded{}), do: nil
  defp loaded(other), do: other
end
