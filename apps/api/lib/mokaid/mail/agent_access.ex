defmodule Mokaid.Mail.AgentAccess do
  @moduledoc "Short-lived, server-issued Mail authority for conversations and agent runs."
  import Ecto.Query
  alias Mokaid.{Agents, Mail, Members, Permissions, Repo, Tasks}
  alias Mokaid.AI.{RuntimeParticipant, RuntimePolicy, RuntimeRun}
  alias Mokaid.Tasks.TaskExecutionRun

  @salt "workspace-mail-tools-v1"
  @tools %{
    "list" => "list_mail_accounts",
    "search" => "search_mail",
    "read" => "read_mail_message",
    "save_attachment" => "save_mail_attachment"
  }

  def for_member(workspace_id, member) do
    issue(workspace_id, member && member.id, %{"kind" => "coordinator"})
  end

  def for_chat(workspace_id, trigger) do
    issue(workspace_id, trigger.author_member_id, %{
      "kind" => "chat",
      "agent_id" => trigger.agent_id,
      "message_id" => trigger.id,
      "conversation_id" => trigger.conversation_id
    })
  end

  def for_run(%TaskExecutionRun{} = run, task, colleagues \\ []) do
    if task && task.workspace_id == run.workspace_id do
      ids = Enum.map(colleagues, &(&1[:id] || &1["id"]))

      issue(run.workspace_id, task.created_by_member_id, %{
        "kind" => "run",
        "run_id" => run.id,
        "task_id" => task.id,
        "agent_id" => run.agent_id,
        "allowed_agent_ids" => Enum.uniq([run.agent_id | ids])
      })
    else
      unavailable()
    end
  end

  def authorize(token, action, acting_agent_id \\ nil)

  def authorize(token, action, acting_agent_id) when is_binary(token) do
    with tool when is_binary(tool) <- @tools[action],
         {:ok, claims} <- Phoenix.Token.verify(MokaidWeb.Endpoint, @salt, token, max_age: 86_400),
         true <- is_map(claims),
         true <- valid_lifetime?(claims),
         {:ok, member} <- live_member(claims["workspace_id"], claims["member_id"]),
         {:ok, context} <- live_context(claims, member, action, tool, acting_agent_id, :call) do
      {:ok, context}
    else
      _ -> {:error, :mail_access_denied}
    end
  end

  def authorize(_, _, _), do: {:error, :mail_access_denied}

  # A recovered run may retain an expired checkpoint capability. Its signature
  # proves the original scope only: every current authority check still applies,
  # and neither conversations nor additional agents can gain access by renewal.
  def refresh(token, action, acting_agent_id \\ nil)

  def refresh(token, action, acting_agent_id) when is_binary(token) do
    with tool when is_binary(tool) <- @tools[action],
         {:ok, %{"kind" => "run"} = claims} <-
           Phoenix.Token.verify(MokaidWeb.Endpoint, @salt, token, max_age: :infinity),
         {:ok, member} <- live_member(claims["workspace_id"], claims["member_id"]),
         {:ok, _} <- live_context(claims, member, action, tool, acting_agent_id, :call) do
      renewed = Map.put(claims, "expires_at", System.system_time(:second) + 86_400)
      {:ok, %{token: Phoenix.Token.sign(MokaidWeb.Endpoint, @salt, renewed)}}
    else
      _ -> {:error, :mail_access_denied}
    end
  end

  def refresh(_, _, _), do: {:error, :mail_access_denied}

  defp issue(workspace_id, member_id, scope) do
    claims =
      Map.merge(scope, %{
        "workspace_id" => workspace_id,
        "member_id" => member_id,
        "expires_at" =>
          System.system_time(:second) + if(scope["kind"] == "run", do: 86_400, else: 900)
      })

    token = Phoenix.Token.sign(MokaidWeb.Endpoint, @salt, claims)

    # Do not expose even an inventory when the initiating member/agent cannot
    # currently read Mail. Provider credentials never form part of this payload.
    allowed =
      with {:ok, member} <- live_member(workspace_id, member_id),
           do: live_context(claims, member, "list", @tools["list"], scope["agent_id"], :issue)

    case allowed do
      {:ok, _} ->
        %{
          token: token,
          scope: "workspace",
          capabilities:
            if(scope["kind"] == "run", do: Map.keys(@tools), else: ~w(list search read)),
          search_coverage: "synchronized messages",
          accounts:
            Enum.map(Mail.list_accounts(workspace_id), fn account ->
              Map.take(account, [:id, :email_address, :provider, :status, :last_sync_at])
            end)
        }

      _ ->
        unavailable()
    end
  end

  defp unavailable, do: %{scope: "workspace", capabilities: [], accounts: [], unavailable: true}

  defp valid_lifetime?(%{"expires_at" => exp}) when is_integer(exp),
    do: exp > System.system_time(:second)

  defp valid_lifetime?(_), do: false

  defp live_member(workspace_id, member_id) do
    with {:ok, _} <- Ecto.UUID.cast(workspace_id),
         {:ok, _} <- Ecto.UUID.cast(member_id),
         %{deleted_at: nil} <- Repo.get(Mokaid.Workspaces.Workspace, workspace_id),
         %{status: "active"} = member <- Members.get_member(workspace_id, member_id),
         true <- Mokaid.Accounts.User.active?(member.user),
         :ok <- Permissions.authorize(member, "workspace.view"),
         :ok <- Permissions.authorize(member, "agents.view") do
      {:ok, member}
    else
      _ -> {:error, :mail_access_denied}
    end
  end

  defp live_context(%{"kind" => "coordinator"} = claims, member, action, _tool, nil, _mode)
       when action in ~w(list search read) do
    with :ok <- Permissions.authorize(member, "agents.run_ai") do
      {:ok, context(claims, member, nil)}
    end
  end

  defp live_context(%{"kind" => "chat"} = claims, member, action, tool, actor, _mode)
       when action in ~w(list search read) do
    with true <- actor in [nil, claims["agent_id"]],
         {:ok, agent} <- live_agent(claims["workspace_id"], claims["agent_id"], tool),
         %{author_kind: "member"} = message <-
           Repo.get(Mokaid.AgentChat.ChatMessage, claims["message_id"]),
         true <-
           message.workspace_id == member.workspace_id and message.author_member_id == member.id,
         true <-
           message.agent_id == agent.id and message.conversation_id == claims["conversation_id"],
         %{status: "active"} <-
           Mokaid.AgentChat.get_conversation(member.workspace_id, message.conversation_id) do
      {:ok, context(claims, member, agent.id)}
    else
      _ -> {:error, :mail_access_denied}
    end
  end

  defp live_context(%{"kind" => "run"} = claims, member, _action, tool, actor, mode) do
    actor = actor || claims["agent_id"]

    with true <- actor in (claims["allowed_agent_ids"] || []),
         %{} = run <- Tasks.get_run(claims["run_id"]),
         true <- run.workspace_id == member.workspace_id and run.task_id == claims["task_id"],
         true <- run.agent_id == claims["agent_id"],
         true <-
           run.status in if(mode == :issue,
             do: ~w(queued running waiting_for_approval waiting_for_user_input),
             else: ~w(queued running)
           ),
         %{} = task <- Tasks.get_task(member.workspace_id, run.task_id),
         true <-
           task.created_by_member_id == member.id and task.assigned_agent_id == run.agent_id,
         true <- task.status not in ~w(completed canceled),
         {:ok, _lead} <- live_agent(member.workspace_id, run.agent_id, tool),
         {:ok, _agent} <- live_agent(member.workspace_id, actor, tool),
         :ok <- managed_authority(run, actor, mode) do
      {:ok, context(claims, member, actor)}
    else
      _ -> {:error, :mail_access_denied}
    end
  end

  defp live_context(_, _, _, _, _, _), do: {:error, :mail_access_denied}

  defp context(claims, member, actor) do
    %{
      workspace_id: member.workspace_id,
      member: member,
      agent_id: actor,
      run_id: claims["run_id"],
      task_id: claims["task_id"]
    }
  end

  defp live_agent(workspace_id, agent_id, tool) do
    with {:ok, _} <- Ecto.UUID.cast(agent_id),
         %{} = agent <- Agents.get_agent(workspace_id, agent_id),
         true <- agent.kind in ~w(ai hybrid) and agent.ai_enabled,
         true <- is_nil(agent.archived_at) and agent.status not in ~w(archived training offline),
         false <- disabled?(agent, tool) do
      {:ok, agent}
    else
      _ -> {:error, :mail_access_denied}
    end
  end

  defp disabled?(agent, tool) do
    rules = Agents.autonomy_payload(agent).rules

    Enum.any?(Map.get(agent.tool_preferences || %{}, "disabled", []), &matches?(&1, tool)) or
      Enum.any?(rules, &(&1.behavior == "deny" and matches?(&1.tool_pattern, tool)))
  end

  defp matches?(pattern, value) when is_binary(pattern) do
    source =
      pattern |> Regex.escape() |> String.replace("\\*", ".*") |> String.replace("\\?", ".")

    Regex.match?(Regex.compile!("\\A" <> source <> "\\z"), value)
  end

  defp matches?(_, _), do: false

  defp managed_authority(run, actor, mode) do
    case Repo.get_by(RuntimeRun, run_id: run.id) do
      nil ->
        :ok

      runtime ->
        policy = RuntimePolicy.payload(run.workspace_id)
        now = DateTime.utc_now()

        leases =
          Repo.all(
            from p in RuntimeParticipant,
              where:
                p.workspace_id == ^run.workspace_id and p.run_id == ^run.id and
                  is_nil(p.released_at) and p.lease_expires_at > ^now,
              select: p.agent_id
          )

        # Recovery dispatch precedes renewing a participant lease. Issuing a
        # capability must not permanently omit Mail from that recovered run;
        # every actual tool call still requires both current leases.
        if policy.enabled and policy.data_policy_accepted and runtime.status == "reserved" and
             is_nil(runtime.finalized_at) and
             (mode == :issue or (run.agent_id in leases and actor in leases)),
           do: :ok,
           else: {:error, :mail_access_denied}
    end
  end
end
