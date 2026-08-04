defmodule Mokaid.AI.Dispatcher do
  @moduledoc """
  Intelligent task dispatch.

  Given a natural-language instruction and optional attached files (dropped
  on the 3D office), decides:

    * which existing agent fits the request best (with confidence + reason),
    * whether a custom agent should be created instead (only when no agent
      is competent, or as a user choice when both options are reasonable),
    * which MCP connections would make the work faster (existing ones that
      only need a grant, or catalog servers worth connecting).

  The decision is delegated to the AI worker's LLM when reachable and falls
  back to a deterministic skill-matching heuristic otherwise, so the flow
  keeps working offline.
  """

  import Ecto.Query

  alias Mokaid.Agents
  alias Mokaid.Drive.DriveItem
  alias Mokaid.MCP
  alias Mokaid.Repo
  alias Mokaid.Tasks
  alias Mokaid.Tasks.Task, as: WorkTask

  @priorities ~w(low medium high urgent)

  ## ---------- Analyze ----------

  @doc """
  Analyzes an instruction + files and returns a recommendation payload:

      %{
        task: %{title, description, priority},
        recommendation: %{mode, agent_id, confidence, reason, alternatives, custom_agent},
        mcp_suggestions: [%{server_key, server_name, reason, status, installation_id, auth_kind}]
      }
  """
  def analyze(workspace_id, params) do
    instruction = String.trim(params["instruction"] || "")
    files = normalize_files(params["files"] || [])

    if instruction == "" and files == [] do
      {:error, :empty_request}
    else
      roster = dispatchable_agents(workspace_id)
      installations = connected_installations(workspace_id)
      servers = MCP.list_servers()

      base =
        case worker_analyze(instruction, files, roster, installations, servers) do
          {:ok, result} ->
            normalize_worker_result(result, roster, servers) ||
              heuristic_analysis(workspace_id, instruction, files, roster, servers)

          :error ->
            heuristic_analysis(workspace_id, instruction, files, roster, servers)
        end

      # Requested domains let every UI (New Task, detail panel reassignment)
      # warn about out-of-specialty assignments consistently.
      base = Map.put(base, :domain_categories, detect_categories(instruction, files))

      {:ok, decorate_mcp_suggestions(base, workspace_id, installations, servers)}
    end
  end

  @doc """
  Best-fit agent for a sub-brief using the offline skill heuristic (no LLM
  round-trip) — used by the composite orchestrator to staff each wave.
  """
  def best_agent(workspace_id, instruction) do
    categories = detect_categories(instruction, [])
    signals = signal_tokens(instruction, categories)

    workspace_id
    |> dispatchable_agents()
    |> Enum.map(fn entry ->
      {entry.agent, agent_score(entry.agent, signals, categories) * 10 - entry.open_tasks}
    end)
    |> Enum.sort_by(fn {_agent, score} -> -score end)
    |> case do
      [{agent, _score} | _] -> agent
      [] -> nil
    end
  end

  ## ---------- Confirm ----------

  @doc """
  Creates the task (and the custom agent when requested), links dropped
  files, applies MCP grants and starts the AI run.
  """
  def confirm(workspace_id, member, params) do
    instruction = String.trim(params["instruction"] || "")
    task_params = params["task"] || %{}
    drive_ids = List.wrap(params["drive_item_ids"])

    with {:ok, agent} <- resolve_agent(workspace_id, member, params),
         {:ok, task} <-
           Tasks.create_task(
             workspace_id,
             %{
               "title" => presence(task_params["title"]) || derive_title(instruction, drive_ids),
               "description" => presence(task_params["description"]) || instruction,
               "priority" => normalize_priority(task_params["priority"]),
               "project_id" => presence(task_params["project_id"]),
               "assigned_agent_id" => agent && agent.id,
               "metadata" => %{
                 "source" => "dispatch",
                 "instruction" => instruction,
                 "drive_item_ids" => drive_ids,
                 "domain_requested" => detect_categories(instruction, []),
                 "capability_match" => normalize_capability_match(params["capability_match"])
               }
             },
             member
           ) do
      link_drive_items(workspace_id, task.id, drive_ids)
      apply_grants(workspace_id, agent, List.wrap(params["grant_installation_ids"]), member)

      run =
        if params["start_now"] != false and agent != nil and agent.kind != "human_linked" do
          # Composite requests are decomposed inside start_run (waves of child
          # missions); ordinary ones go straight to the worker queue.
          case Mokaid.AI.start_run(task, %{
                 "instruction" => instruction,
                 "drive_item_ids" => drive_ids
               }) do
            {:ok, run} -> run
            _ -> nil
          end
        end

      {:ok, %{task: Tasks.get_task(workspace_id, task.id), agent: agent, run: run}}
    end
  end

  # Sanitized snapshot of the routing decision, persisted on the task so the
  # UI can keep showing why this agent was (or wasn't) a fit.
  defp normalize_capability_match(%{} = match) do
    %{
      "mode" => to_string(match["mode"] || ""),
      "confidence" => clamp_confidence(match["confidence"]),
      "reason" => String.slice(to_string(match["reason"] || ""), 0, 500),
      "warning_shown" => match["warning_shown"] == true
    }
  end

  defp normalize_capability_match(_), do: nil

  @doc "Files attached to a task via dispatch, with presigned download URLs for the AI worker."
  def attached_files(workspace_id, drive_item_ids) when is_list(drive_item_ids) do
    ids = Enum.filter(drive_item_ids, &is_binary/1)

    if ids == [] do
      []
    else
      Repo.all(
        from d in DriveItem,
          where: d.workspace_id == ^workspace_id and d.id in ^ids and d.kind == "file"
      )
      |> Enum.map(&file_entry/1)
    end
  end

  def attached_files(_workspace_id, _), do: []

  @doc """
  Every active file the task can work with: the drive items linked to the
  task (initial attachments, files added later, previous agent outputs) plus
  any explicitly referenced ids — so a relaunched mission sees the complete
  current material, not just what was dropped at creation time.
  """
  def task_files(workspace_id, task_id, extra_ids \\ []) do
    ids = Enum.filter(List.wrap(extra_ids), &is_binary/1)

    Repo.all(
      from d in DriveItem,
        where:
          d.workspace_id == ^workspace_id and d.kind == "file" and d.status == "active" and
            (d.linked_task_id == ^task_id or d.id in ^ids),
        order_by: [asc: d.inserted_at]
    )
    |> Enum.map(&file_entry/1)
  end

  defp file_entry(item) do
    download_url =
      case item.storage_key && Mokaid.Storage.download_url(item.storage_key) do
        {:ok, url} -> url
        _ -> nil
      end

    %{
      id: item.id,
      name: item.name,
      mime_type: item.mime_type,
      size_bytes: item.size_bytes,
      download_url: download_url,
      # Lets the planner iterate on the agent's own previous results instead
      # of always restarting from the user's original upload.
      source: if(item.created_by_agent_id, do: "agent_output", else: "input")
    }
  end

  ## ---------- Worker (LLM) analysis ----------

  defp worker_analyze(instruction, files, roster, installations, servers) do
    config = Application.fetch_env!(:mokaid, :ai_worker)

    if config[:dispatch] == :http and Mokaid.AI.WorkerClient.absolute_url?(config[:url]) do
      payload = %{
        instruction: instruction,
        files: files,
        agents: Enum.map(roster, &roster_entry/1),
        mcp_connected:
          Enum.map(installations, fn i ->
            %{
              installation_id: i.id,
              server_key: i.server.key,
              name: i.server.name,
              category: i.server.category
            }
          end),
        mcp_available:
          servers
          |> Enum.reject(fn s -> Enum.any?(installations, &(&1.server.key == s.key)) end)
          |> Enum.map(fn s ->
            %{key: s.key, name: s.name, category: s.category, description: s.description}
          end)
      }

      case Req.post(
             url: "#{String.trim_trailing(config[:url], "/")}/dispatch/analyze",
             json: payload,
             headers: [{"authorization", "Bearer #{config[:token]}"}],
             receive_timeout: 30_000,
             retry: false
           ) do
        {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
        _ -> :error
      end
    else
      :error
    end
  end

  defp roster_entry(%{agent: agent, open_tasks: open_tasks}) do
    learning = get_in(agent.capabilities, ["learning"]) || %{}

    %{
      id: agent.id,
      name: agent.display_name,
      role_title: agent.role_title,
      department: agent.department,
      status: agent.status,
      skills: agent.skills,
      open_tasks: open_tasks,
      specialty: learning["specialty"],
      missions_total: learning["missions_total"] || 0
    }
  end

  # Validates and reshapes the worker's JSON. Returns nil when the payload
  # is unusable so the caller falls back to the heuristic.
  defp normalize_worker_result(result, roster, servers) do
    rec = result["recommendation"] || %{}
    agent_ids = MapSet.new(roster, & &1.agent.id)
    server_keys = MapSet.new(servers, & &1.key)

    mode =
      case rec["mode"] do
        m when m in ~w(existing_agent custom_agent user_choice) -> m
        _ -> nil
      end

    agent_id =
      case rec["agent_id"] do
        id when is_binary(id) -> if MapSet.member?(agent_ids, id), do: id
        _ -> nil
      end

    cond do
      mode == nil -> nil
      mode in ~w(existing_agent user_choice) and agent_id == nil -> nil
      true -> build_normalized(result, rec, mode, agent_id, agent_ids, server_keys)
    end
  end

  defp build_normalized(result, rec, mode, agent_id, agent_ids, server_keys) do
    task = result["task"] || %{}

    alternatives =
      (rec["alternatives"] || [])
      |> Enum.filter(fn alt ->
        is_map(alt) and is_binary(alt["agent_id"]) and MapSet.member?(agent_ids, alt["agent_id"])
      end)
      |> Enum.take(2)
      |> Enum.map(fn alt ->
        %{
          agent_id: alt["agent_id"],
          confidence: clamp_confidence(alt["confidence"]),
          reason: to_string(alt["reason"] || "")
        }
      end)

    custom_agent =
      case rec["custom_agent"] do
        %{"display_name" => name} = custom when is_binary(name) ->
          domain_hint =
            custom["archetype_key"] ||
              Mokaid.Agents.Archetypes.archetype_key_for_domain(custom["domain"])

          %{
            display_name: name,
            role_title: custom["role_title"],
            department: custom["department"],
            archetype_key: domain_hint,
            skills: normalize_skills(custom["skills"])
          }

        _ ->
          nil
      end

    mcp_suggestions =
      (result["mcp_suggestions"] || [])
      |> Enum.filter(fn s ->
        is_map(s) and is_binary(s["server_key"]) and MapSet.member?(server_keys, s["server_key"])
      end)
      |> Enum.take(3)
      |> Enum.map(fn s ->
        %{server_key: s["server_key"], reason: to_string(s["reason"] || "")}
      end)

    %{
      task: %{
        title: presence(task["title"]) || "New task",
        description: to_string(task["description"] || ""),
        priority: normalize_priority(task["priority"])
      },
      recommendation: %{
        mode: mode,
        agent_id: agent_id,
        confidence: clamp_confidence(rec["confidence"]),
        reason: to_string(rec["reason"] || ""),
        alternatives: alternatives,
        custom_agent: custom_agent
      },
      mcp_suggestions: mcp_suggestions
    }
  end

  ## ---------- Heuristic fallback ----------

  @stopwords ~w(the and for with that this from into about les des une pour avec dans que qui est cette sur nous vous)

  @file_categories %{
    "design" => ~w(fig sketch xd psd),
    "data" => ~w(csv xlsx xls json parquet sql),
    "document" => ~w(pdf doc docx txt md rtf odt),
    "media" => ~w(png jpg jpeg gif webp svg mp4 mov avi),
    "code" => ~w(js ts tsx py ex exs rb go java rs c cpp html css zip),
    "slides" => ~w(ppt pptx key)
  }

  # Keep in sync with Mokaid.Agents.SkillLearning.@category_keywords and the
  # domains of Mokaid.Agents.Archetypes — a request should map to the same
  # domain everywhere (dispatch warnings, learning, specialist proposals).
  @category_keywords %{
    "design" => ~w(design figma maquette wireframe prototype logo brand branding),
    "data" => ~w(data analyse analysis spreadsheet tableur report rapport metrics kpi excel),
    "document" => ~w(document redaction writing resume summary contrat brief write),
    "media" => ~w(image photo video visuel media asset),
    # Web / product builds must land in code — "site", "ecommerce", "app" etc.
    "code" =>
      ~w(code coding development developpement developpeur développeur programmer programmation software logiciel bug feature api script deploy site website webapp web ecommerce e-commerce boutique frontend backend fullstack application appli saas shopify wordpress cms plateforme),
    "slides" => ~w(presentation slides deck pitch),
    "legal" =>
      ~w(legal juridique contract rgpd gdpr compliance conformite clause nda avocat lawyer),
    "finance" =>
      ~w(finance budget comptable comptabilite invoice facture forecast tresorerie cashflow fiscal tax),
    "marketing" => ~w(marketing seo campagne campaign newsletter social ads audience growth),
    "sales" => ~w(sales vente vendre vends prospection pipeline lead deal crm),
    "research" => ~w(research recherche etude benchmark veille survey sondage),
    "sciences" => ~w(scientifique scientific experiment hypothesis laboratoire laboratory),
    "ops" => ~w(recrutement recruiting onboarding hiring rh embauche),
    "product" => ~w(roadmap backlog user-story spec produit product),
    "security" => ~w(securite security vulnerabilite vulnerability pentest phishing),
    "devops" => ~w(devops deployment deploiement docker kubernetes terraform infra ci/cd),
    "support" => ~w(support ticket faq helpdesk sav)
  }

  # Role / department phrases → domain (used when specialty is not yet set).
  @role_domain_hints [
    {~w(software engineer developer développeur developpeur devops coding programming full-stack fullstack), "code"},
    {~w(designer design ui ux figma creative), "design"},
    {~w(data scientist analyst analytics ml), "data"},
    {~w(writer content redacteur rédacteur copywriter editorial), "document"},
    {~w(legal lawyer avocat counsel compliance jurist juridique), "legal"},
    {~w(finance accountant comptable cfo treasury fiscal), "finance"},
    {~w(marketing growth seo campaign brand), "marketing"},
    {~w(sales account commercial sdr ae), "sales"},
    {~w(research researcher scientifique scientist), "research"},
    {~w(product manager pm product owner), "product"},
    {~w(security appsec infosec cybersecurity), "security"},
    {~w(support helpdesk customer success cs), "support"},
    {~w(media video film audio production), "media"},
    {~w(ops hr operations people), "ops"}
  ]

  defp heuristic_analysis(workspace_id, instruction, files, roster, servers) do
    categories = detect_categories(instruction, files)
    signals = signal_tokens(instruction, categories)

    scored =
      roster
      |> Enum.map(fn entry ->
        score = agent_score(entry.agent, signals, categories)
        graph_bonus =
          graph_bonus_for_agent(workspace_id, entry.agent, instruction, categories)

        # Slight penalty per open task so equally-skilled but freer agents win.
        {entry, max(score * 10 + graph_bonus - entry.open_tasks, 0)}
      end)
      |> Enum.sort_by(fn {_entry, score} -> -score end)

    {best_entry, best_score} = List.first(scored) || {nil, 0}
    confidence = if best_score > 0, do: min(30 + best_score * 6, 92), else: 15

    # Detect out-of-scope: the best agent is specialised in a different domain.
    {mode, reason, custom_agent} =
      out_of_scope_check(best_entry, confidence, categories, roster)

    alternatives =
      scored
      |> Enum.drop(1)
      |> Enum.take(2)
      |> Enum.filter(fn {_entry, score} -> score > 0 end)
      |> Enum.map(fn {entry, score} ->
        %{
          agent_id: entry.agent.id,
          confidence: min(30 + score * 6, 85),
          reason: "Related skills and availability"
        }
      end)

    %{
      task: %{
        title: derive_title(instruction, Enum.map(files, & &1["name"])),
        description: instruction,
        priority: infer_priority(instruction)
      },
      recommendation: %{
        mode: mode,
        agent_id: if(mode == "custom_agent", do: nil, else: best_entry && best_entry.agent.id),
        confidence: confidence,
        reason: reason,
        alternatives: alternatives,
        custom_agent: custom_agent
      },
      mcp_suggestions: heuristic_mcp_suggestions(instruction, categories, servers)
    }
  end

  # Returns `{mode, reason, custom_agent}` with out-of-scope logic applied.
  defp out_of_scope_check(nil, _confidence, categories, _roster) do
    {"custom_agent", heuristic_reason("custom_agent", nil, categories),
     custom_proposal(categories)}
  end

  defp out_of_scope_check(best_entry, confidence, categories, roster) when confidence >= 60 do
    agent_domains = agent_domains(best_entry.agent)

    # Wrong specialist for the request (archetype / role / specialty), and nobody
    # on the roster covers the requested domains → propose creating a match.
    if categories != [] and agent_domains != [] and
         MapSet.disjoint?(MapSet.new(agent_domains), MapSet.new(categories)) and
         all_agents_lack_domain?(roster, categories) do
      domain_label = Enum.join(categories, ", ")
      agent_label = Enum.join(agent_domains, ", ")

      reason =
        "#{best_entry.agent.display_name} specialises in #{agent_label}; " <>
          "this mission is about #{domain_label}. " <>
          "A dedicated agent would be more efficient."

      {"user_choice", reason, custom_proposal(categories)}
    else
      {"existing_agent", heuristic_reason("existing_agent", best_entry.agent, categories), nil}
    end
  end

  defp out_of_scope_check(best_entry, confidence, categories, _roster) when confidence >= 40 do
    {"user_choice", heuristic_reason("user_choice", best_entry.agent, categories),
     custom_proposal(categories)}
  end

  defp out_of_scope_check(_best_entry, _confidence, categories, _roster) do
    {"custom_agent", heuristic_reason("custom_agent", nil, categories),
     custom_proposal(categories)}
  end

  # True when no agent in the roster covers any of the requested domains
  # (via specialty, archetype, role title, or skills).
  defp all_agents_lack_domain?(roster, domains) do
    wanted = MapSet.new(domains)

    Enum.all?(roster, fn entry ->
      MapSet.disjoint?(MapSet.new(agent_domains(entry.agent)), wanted)
    end)
  end

  defp detect_categories(instruction, files) do
    extension_categories =
      files
      |> Enum.map(fn f ->
        f["name"] |> to_string() |> Path.extname() |> String.trim_leading(".")
      end)
      |> Enum.flat_map(fn ext ->
        for {category, exts} <- @file_categories, ext in exts, do: category
      end)

    text = String.downcase(instruction)

    keyword_categories =
      for {category, keywords} <- @category_keywords,
          Enum.any?(keywords, &keyword_in_text?(text, &1)),
          do: category

    Enum.uniq(extension_categories ++ keyword_categories)
  end

  # Word-boundary match so short tokens like "ads"/"tax"/"api" don't fire inside
  # unrelated words (and so "media" never matches "ecommerce").
  defp keyword_in_text?(text, keyword) when is_binary(text) and is_binary(keyword) do
    # Hyphenated forms: treat "-" as a separator so "e-commerce" matches "ecommerce"
    # only when the keyword itself is listed with that spelling.
    pattern =
      ~r/(^|[^a-zà-ÿ0-9])#{Regex.escape(keyword)}([^a-zà-ÿ0-9]|$)/u

    Regex.match?(pattern, text)
  end

  defp keyword_in_text?(_, _), do: false

  defp signal_tokens(instruction, categories) do
    instruction_tokens =
      instruction
      |> String.downcase()
      |> String.split(~r/[^a-zà-ÿ0-9\+#]+/u, trim: true)
      |> Enum.reject(&(&1 in @stopwords or String.length(&1) < 3))

    category_tokens = Enum.flat_map(categories, &Map.get(@category_keywords, &1, []))
    Enum.uniq(instruction_tokens ++ category_tokens)
  end

  defp agent_score(agent, signals, categories) do
    haystack =
      [
        agent.display_name,
        agent.role_title,
        agent.department
        | Enum.map(agent.skills || [], fn skill -> skill["name"] || skill[:name] end)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(" ", &String.downcase(to_string(&1)))

    skill_hits = Enum.count(signals, &String.contains?(haystack, &1))
    domain_hits = domain_alignment_score(agent, categories)

    max(skill_hits + domain_hits, 0)
  end

  # Dominates pure token / graph noise: a code request must prefer engineers
  # over e.g. legal even if the knowledge graph overlaps on common French words.
  defp domain_alignment_score(_agent, []), do: 0

  defp domain_alignment_score(agent, categories) do
    domains = agent_domains(agent)
    matches = Enum.count(categories, &(&1 in domains))

    cond do
      matches > 0 -> matches * 5
      domains == [] -> 0
      true -> -4
    end
  end

  defp agent_domains(agent) do
    caps = agent.capabilities || %{}
    learning = Map.get(caps, "learning") || %{}
    domain_pack = Map.get(caps, "domain_pack") || %{}

    specialty = learning["specialty"]
    archetype_key = domain_pack["archetype"] || learning["archetype"]

    from_specialty =
      if is_binary(specialty) and specialty != "", do: [specialty], else: []

    from_archetype =
      case Mokaid.Agents.Archetypes.get_archetype(archetype_key) do
        %{domain: domain} when is_binary(domain) and domain != "" -> [domain]
        _ -> []
      end

    from_role = role_department_domains(agent.role_title, agent.department)
    from_skills = skill_name_domains(agent.skills)

    Enum.uniq(from_specialty ++ from_archetype ++ from_role ++ from_skills)
  end

  defp role_department_domains(role_title, department) do
    text =
      [role_title, department]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(" ", &String.downcase(to_string(&1)))

    for {hints, domain} <- @role_domain_hints,
        Enum.any?(hints, &keyword_in_text?(text, &1)),
        do: domain
  end

  # Map known starter skill names back to domains (coding ≠ keyword "code").
  defp skill_name_domains(skills) when is_list(skills) do
    names =
      skills
      |> Enum.map(fn s -> s["name"] || s[:name] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase(to_string(&1)))

    []
    |> maybe_skill_domain(names, "code", ~w(coding debugging code-review architecture))
    |> maybe_skill_domain(names, "design", ~w(ui-design figma branding design-systems ux))
    |> maybe_skill_domain(names, "data", ~w(data-analysis statistics modeling reporting spreadsheets))
    |> maybe_skill_domain(names, "document", ~w(writing editing storytelling presentations research))
    |> maybe_skill_domain(names, "legal", ~w(contracts compliance legal-research risk))
    |> maybe_skill_domain(names, "finance", ~w(financial-analysis budgeting forecasting))
    |> maybe_skill_domain(names, "marketing", ~w(seo content-marketing campaigns branding))
    |> maybe_skill_domain(names, "sales", ~w(outbound discovery negotiation crm))
    |> maybe_skill_domain(names, "security", ~w(threat-modeling incident-response))
    |> maybe_skill_domain(names, "devops", ~w(ci-cd infrastructure observability runbooks))
    |> maybe_skill_domain(names, "media", ~w(video scripting transcription image-editing))
    |> maybe_skill_domain(names, "product", ~w(roadmapping specs prioritization discovery))
    |> maybe_skill_domain(names, "support", ~w(support troubleshooting customer-success))
    |> Enum.uniq()
  end

  defp skill_name_domains(_), do: []

  defp maybe_skill_domain(acc, names, domain, domain_skills) do
    if Enum.any?(names, &(&1 in domain_skills)), do: [domain | acc], else: acc
  end

  # Knowledge-graph overlap must not override an explicit domain mismatch
  # (e.g. legal corpus mentioning "site"/"tables" on an ecommerce build request).
  defp graph_bonus_for_agent(workspace_id, agent, instruction, categories) do
    domains = agent_domains(agent)

    if categories != [] and domains != [] and
         MapSet.disjoint?(MapSet.new(domains), MapSet.new(categories)) do
      0
    else
      graph_overlap_bonus(workspace_id, agent.id, instruction)
    end
  end

  defp custom_proposal(categories) do
    domain = List.first(categories)
    key = Mokaid.Agents.Archetypes.archetype_key_for_domain(domain)
    archetype = Mokaid.Agents.Archetypes.get_archetype(key)

    %{
      display_name: archetype.name,
      role_title: archetype.role_title,
      department: archetype.department,
      archetype_key: archetype.key,
      skills:
        Enum.map(archetype.skills, fn s ->
          %{name: s, level: 40}
        end)
    }
  end

  defp heuristic_reason("existing_agent", agent, _categories),
    do: "#{agent.display_name}'s skills match this request best."

  defp heuristic_reason("user_choice", agent, _categories),
    do:
      "#{agent.display_name} can handle it, but a dedicated agent may fit this kind of request even better."

  defp heuristic_reason("custom_agent", nil, []),
    do: "No existing agent covers this request well — a purpose-built agent is recommended."

  defp heuristic_reason("custom_agent", nil, categories),
    do:
      "No existing agent covers #{Enum.join(categories, ", ")} work well — a purpose-built agent is recommended."

  defp heuristic_reason("custom_agent", _agent, []),
    do: "No existing agent covers this request well — a purpose-built agent is recommended."

  defp heuristic_reason("custom_agent", _agent, categories),
    do:
      "No existing agent covers #{Enum.join(categories, ", ")} work well — a purpose-built agent is recommended."

  @category_servers %{
    "design" => ["figma"],
    "code" => ["github"],
    "data" => ["google_sheets"],
    "document" => ["notion", "google_drive"],
    "slides" => ["google_docs"]
  }

  defp heuristic_mcp_suggestions(instruction, categories, servers) do
    text = String.downcase(instruction)
    by_key = Map.new(servers, &{&1.key, &1})

    from_categories =
      categories
      |> Enum.flat_map(&Map.get(@category_servers, &1, []))
      |> Enum.filter(&Map.has_key?(by_key, &1))
      |> Enum.map(fn key -> %{server_key: key, reason: "Matches the attached files"} end)

    from_mentions =
      servers
      |> Enum.filter(fn s -> String.contains?(text, String.downcase(s.name)) end)
      |> Enum.map(fn s -> %{server_key: s.key, reason: "Mentioned in your instruction"} end)

    (from_mentions ++ from_categories)
    |> Enum.uniq_by(& &1.server_key)
    |> Enum.take(3)
  end

  ## ---------- MCP suggestion decoration ----------

  # Enriches each suggestion with its connection status relative to the
  # recommended agent: ready / needs_grant / not_installed.
  defp decorate_mcp_suggestions(analysis, workspace_id, installations, servers) do
    servers_by_key = Map.new(servers, &{&1.key, &1})
    installations_by_key = Map.new(installations, &{&1.server.key, &1})

    granted_installation_ids =
      case analysis.recommendation do
        %{mode: "existing_agent", agent_id: agent_id} when is_binary(agent_id) ->
          workspace_id
          |> MCP.list_grants_for_agent(agent_id)
          |> Enum.filter(& &1.granted)
          |> MapSet.new(& &1.installation_id)

        _ ->
          MapSet.new()
      end

    suggestions =
      analysis.mcp_suggestions
      |> Enum.flat_map(fn suggestion ->
        case Map.get(servers_by_key, suggestion.server_key) do
          nil ->
            []

          server ->
            installation = Map.get(installations_by_key, server.key)

            status =
              cond do
                installation == nil -> "not_installed"
                MapSet.member?(granted_installation_ids, installation.id) -> "ready"
                true -> "needs_grant"
              end

            [
              %{
                server_key: server.key,
                server_name: server.name,
                auth_kind: server.auth_kind,
                logo_slug: server.logo_slug,
                reason: suggestion.reason,
                status: status,
                installation_id: installation && installation.id
              }
            ]
        end
      end)

    %{analysis | mcp_suggestions: suggestions}
  end

  ## ---------- Confirm helpers ----------

  defp resolve_agent(workspace_id, _member, %{"agent_id" => id})
       when is_binary(id) and id != "" do
    case Agents.get_agent(workspace_id, id) do
      nil -> {:error, :agent_not_found}
      agent -> {:ok, agent}
    end
  end

  defp resolve_agent(workspace_id, member, %{"custom_agent" => %{} = attrs}) do
    archetype_key =
      attrs["archetype_key"] ||
        infer_archetype_from_custom(attrs)

    with {:ok, agent} <-
           Agents.create_agent(
             workspace_id,
             %{
               "kind" => "ai",
               "display_name" => presence(attrs["display_name"]) || "Custom Agent",
               "role_title" => attrs["role_title"],
               "department" => attrs["department"],
               "archetype_key" => archetype_key,
               "boost_key" => attrs["boost_key"],
               "avatar_config" => %{"primary_color" => random_agent_color()}
             },
             member
           ) do
      {:ok, Repo.preload(agent, [:linked_user, linked_member: :user])}
    end
  end

  defp resolve_agent(_workspace_id, _member, _params), do: {:ok, nil}

  defp infer_archetype_from_custom(attrs) do
    skill_names =
      (attrs["skills"] || [])
      |> Enum.map(fn
        %{"name" => name} -> name
        %{name: name} -> name
        name when is_binary(name) -> name
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase/1)

    cond do
      Enum.any?(skill_names, &(&1 in ~w(coding debugging code-review))) -> "developer"
      Enum.any?(skill_names, &(&1 in ~w(ui-design figma branding))) -> "designer"
      Enum.any?(skill_names, &(&1 in ~w(data-analysis spreadsheets reporting))) -> "data_analyst"
      Enum.any?(skill_names, &(&1 in ~w(writing editing research))) -> "writer"
      Enum.any?(skill_names, &(&1 in ~w(image-editing video content))) -> "media"
      Enum.any?(skill_names, &(&1 in ~w(presentations storytelling design))) -> "presenter"
      true -> "generalist"
    end
  end

  defp link_drive_items(_workspace_id, _task_id, []), do: :ok

  defp link_drive_items(workspace_id, task_id, drive_ids) do
    ids = Enum.filter(drive_ids, &is_binary/1)

    if ids != [] do
      from(d in DriveItem, where: d.workspace_id == ^workspace_id and d.id in ^ids)
      |> Repo.update_all(set: [linked_task_id: task_id, is_ai_readable: true])
    end

    :ok
  end

  defp apply_grants(_workspace_id, nil, _ids, _member), do: :ok
  defp apply_grants(_workspace_id, _agent, [], _member), do: :ok

  defp apply_grants(workspace_id, agent, installation_ids, member) do
    installation_ids
    |> Enum.filter(&is_binary/1)
    |> Enum.each(fn installation_id ->
      if MCP.get_installation(workspace_id, installation_id) do
        MCP.set_grant(workspace_id, agent.id, installation_id, true, member)
      end
    end)

    :ok
  end

  defp graph_overlap_bonus(workspace_id, agent_id, instruction)
       when is_binary(workspace_id) and is_binary(agent_id) and is_binary(instruction) do
    if Mokaid.Knowledge.Graph.enabled?(workspace_id) do
      case Mokaid.Knowledge.Graph.rank_agents_for_task(workspace_id, instruction, [agent_id]) do
        [{^agent_id, score, _}] when is_integer(score) and score > 0 -> min(score * 2, 20)
        _ -> 0
      end
    else
      0
    end
  end

  defp graph_overlap_bonus(_, _, _), do: 0

  ## ---------- Small helpers ----------

  defp dispatchable_agents(workspace_id) do
    open_counts =
      Repo.all(
        from t in WorkTask,
          where:
            t.workspace_id == ^workspace_id and
              t.status in ["to_do", "in_progress", "waiting", "in_review"] and
              not is_nil(t.assigned_agent_id),
          group_by: t.assigned_agent_id,
          select: {t.assigned_agent_id, count(t.id)}
      )
      |> Map.new()

    workspace_id
    |> Agents.list_agents()
    |> Enum.filter(fn agent -> agent.kind in ["ai", "hybrid"] end)
    |> Enum.map(fn agent -> %{agent: agent, open_tasks: Map.get(open_counts, agent.id, 0)} end)
  end

  defp connected_installations(workspace_id) do
    workspace_id
    |> MCP.list_installations()
    |> Enum.filter(&(&1.status == "connected"))
  end

  defp normalize_files(files) when is_list(files) do
    files
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn f ->
      %{
        "drive_item_id" => f["drive_item_id"],
        "name" => to_string(f["name"] || "file"),
        "mime_type" => f["mime_type"],
        "size_bytes" => f["size_bytes"]
      }
    end)
  end

  defp normalize_files(_), do: []

  defp normalize_skills(skills) when is_list(skills) do
    skills
    |> Enum.flat_map(fn
      %{"name" => name} = skill when is_binary(name) ->
        [%{"name" => name, "level" => clamp_confidence(skill["level"] || 70)}]

      %{name: name} = skill when is_binary(name) ->
        [%{"name" => name, "level" => clamp_confidence(skill[:level] || 70)}]

      name when is_binary(name) ->
        [%{"name" => name, "level" => 70}]

      _ ->
        []
    end)
    |> Enum.take(8)
  end

  defp normalize_skills(_), do: []

  defp normalize_priority(priority) when priority in @priorities, do: priority
  defp normalize_priority(_), do: "medium"

  @urgent_words ~w(urgent asap immediately critical critique immédiat)
  @high_words ~w(important quickly rapidement priorité deadline tomorrow demain)

  defp infer_priority(instruction) do
    text = String.downcase(instruction)

    cond do
      Enum.any?(@urgent_words, &String.contains?(text, &1)) -> "urgent"
      Enum.any?(@high_words, &String.contains?(text, &1)) -> "high"
      true -> "medium"
    end
  end

  defp derive_title(instruction, fallback_names) do
    title =
      instruction
      |> String.split(~r/\r?\n/, trim: true)
      |> List.first()
      |> Kernel.||("")
      |> String.trim()

    cond do
      title != "" and String.length(title) <= 80 -> title
      title != "" -> String.slice(title, 0, 77) <> "…"
      fallback_names != [] -> "Process #{Enum.join(Enum.take(fallback_names, 2), ", ")}"
      true -> "New task"
    end
  end

  defp clamp_confidence(value) when is_integer(value), do: value |> max(0) |> min(100)
  defp clamp_confidence(value) when is_float(value), do: value |> round() |> max(0) |> min(100)
  defp clamp_confidence(_), do: 50

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  @agent_colors ~w(#7c5cff #22c55e #06b6d4 #f97316 #ec4899 #eab308 #38bdf8)

  defp random_agent_color, do: Enum.random(@agent_colors)
end
