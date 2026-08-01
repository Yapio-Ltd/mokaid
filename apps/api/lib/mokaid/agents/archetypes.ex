defmodule Mokaid.Agents.Archetypes do
  @moduledoc """
  Catalog of free agent archetypes and paid creation boosts.

  Clients may only send archetype/boost keys — all skill levels, roles and
  credit prices are owned by this module.

  Dual-path creation:
  - `blank` — level-1 agent with weak starter skills (free)
  - specialist archetypes — optionally purchased at level 10 via `boost_l10`
  """

  alias Mokaid.Agents.DomainPacks
  alias Mokaid.Agents.Progression

  @specialist_skill_seed 40
  @blank_skill_seed 15
  @blank_skills ~w(research planning)

  @aliases %{
    "generalist" => "blank",
    "data_analyst" => "data_scientist",
    "designer" => "design",
    "writer" => "writer_content",
    "media" => "media_video",
    "presenter" => "writer_content"
  }

  @archetypes [
    %{
      key: "blank",
      name: "New agent",
      domain: nil,
      tier: "blank",
      description:
        "Starts at level 1 with basic skills. Chooses a role and trains through missions.",
      role_title: "Trainee",
      department: "Operations",
      skills: @blank_skills,
      tags: ~w(blank trainee general learn),
      suggested_mcp: []
    },
    %{
      key: "developer",
      name: "Developer",
      domain: "code",
      tier: "specialist",
      description: "Level-ready software engineer: coding, debugging, reviews, GitHub workflows.",
      role_title: "Software Engineer",
      department: "Engineering",
      skills: ~w(coding debugging code-review architecture),
      tags: ~w(code engineering github software devops),
      suggested_mcp: ["github"]
    },
    %{
      key: "data_scientist",
      name: "Data Scientist",
      domain: "data",
      tier: "specialist",
      description: "Analysis, modeling, spreadsheets and decision-ready reporting.",
      role_title: "Data Scientist",
      department: "Data",
      skills: ~w(data-analysis statistics modeling reporting),
      tags: ~w(data analytics ml sql spreadsheets),
      suggested_mcp: ["google_sheets"]
    },
    %{
      key: "research",
      name: "Researcher",
      domain: "research",
      tier: "specialist",
      description: "Deep research, synthesis, source evaluation and brief writing.",
      role_title: "Research Analyst",
      department: "Research",
      skills: ~w(research synthesis source-critique briefing),
      tags: ~w(research science literature discovery),
      suggested_mcp: []
    },
    %{
      key: "finance",
      name: "Finance",
      domain: "finance",
      tier: "specialist",
      description: "Financial analysis, budgeting, forecasting and investment literacy.",
      role_title: "Finance Analyst",
      department: "Finance",
      skills: ~w(financial-analysis budgeting forecasting modeling),
      tags: ~w(finance accounting trading fp&a),
      suggested_mcp: ["google_sheets"]
    },
    %{
      key: "marketing",
      name: "Marketing",
      domain: "marketing",
      tier: "specialist",
      description: "Growth, SEO, campaigns, brand messaging and content marketing.",
      role_title: "Marketing Specialist",
      department: "Marketing",
      skills: ~w(seo content-marketing campaigns branding),
      tags: ~w(marketing seo growth social media),
      suggested_mcp: ["notion"]
    },
    %{
      key: "sales",
      name: "Sales",
      domain: "sales",
      tier: "specialist",
      description: "Pipeline, outreach, discovery calls and closing playbooks.",
      role_title: "Sales Specialist",
      department: "Sales",
      skills: ~w(outbound discovery negotiation crm),
      tags: ~w(sales revenue pipeline crm),
      suggested_mcp: ["slack"]
    },
    %{
      key: "sciences",
      name: "Sciences",
      domain: "sciences",
      tier: "specialist",
      description: "Scientific method, experimental design and technical communication.",
      role_title: "Science Specialist",
      department: "Science",
      skills: ~w(scientific-method experiment-design literature analysis),
      tags: ~w(science biology chemistry physics lab),
      suggested_mcp: []
    },
    %{
      key: "legal",
      name: "Legal",
      domain: "legal",
      tier: "specialist",
      description:
        "Contracts, compliance checklists and legal research support (not legal advice).",
      role_title: "Legal Specialist",
      department: "Legal",
      skills: ~w(contracts compliance legal-research risk),
      tags: ~w(legal compliance contracts policy),
      suggested_mcp: ["notion"]
    },
    %{
      key: "ops_hr",
      name: "Ops & HR",
      domain: "ops",
      tier: "specialist",
      description: "Operations, people processes, SOPs and internal communications.",
      role_title: "Ops Specialist",
      department: "Operations",
      skills: ~w(operations people-ops sop process-design),
      tags: ~w(ops hr productivity office people),
      suggested_mcp: ["slack", "google_drive"]
    },
    %{
      key: "product",
      name: "Product",
      domain: "product",
      tier: "specialist",
      description: "Roadmaps, specs, prioritization and cross-functional delivery.",
      role_title: "Product Specialist",
      department: "Product",
      skills: ~w(roadmapping specs prioritization discovery),
      tags: ~w(product roadmap pm agents workflow),
      suggested_mcp: ["linear", "notion"]
    },
    %{
      key: "design",
      name: "Design",
      domain: "design",
      tier: "specialist",
      description: "UI/UX, Figma workflows, design systems and brand craft.",
      role_title: "Designer",
      department: "Design",
      skills: ~w(ui-design ux figma design-systems),
      tags: ~w(design ux ui figma creative branding),
      suggested_mcp: ["figma"]
    },
    %{
      key: "writer_content",
      name: "Writer",
      domain: "document",
      tier: "specialist",
      description: "Long-form writing, editing, storytelling and presentations.",
      role_title: "Content Specialist",
      department: "Content",
      skills: ~w(writing editing storytelling presentations),
      tags: ~w(writing content documents slides storytelling),
      suggested_mcp: ["google_docs", "notion"]
    },
    %{
      key: "security",
      name: "Security",
      domain: "security",
      tier: "specialist",
      description: "AppSec, threat modeling, secure reviews and vulnerability triage.",
      role_title: "Security Specialist",
      department: "Security",
      skills: ~w(threat-modeling code-review compliance incident-response),
      tags: ~w(security appsec owasp vuln pentest codeql),
      suggested_mcp: ["github"]
    },
    %{
      key: "devops",
      name: "DevOps",
      domain: "devops",
      tier: "specialist",
      description: "CI/CD, infrastructure, observability and reliable releases.",
      role_title: "DevOps Engineer",
      department: "Engineering",
      skills: ~w(ci-cd infrastructure observability runbooks),
      tags: ~w(devops kubernetes docker terraform sre cicd),
      suggested_mcp: ["github"]
    },
    %{
      key: "support_cs",
      name: "Support & CS",
      domain: "support",
      tier: "specialist",
      description: "Customer support, success playbooks and ticket resolution.",
      role_title: "Support Specialist",
      department: "Support",
      skills: ~w(support troubleshooting customer-success documentation),
      tags: ~w(support helpdesk customer-success tickets zendesk),
      suggested_mcp: ["slack", "notion"]
    },
    %{
      key: "media_video",
      name: "Media & Video",
      domain: "media",
      tier: "specialist",
      description: "Video, audio, scripting and media production workflows.",
      role_title: "Media Specialist",
      department: "Marketing",
      skills: ~w(video scripting editing transcription),
      tags: ~w(video media podcast youtube ffmpeg audio),
      suggested_mcp: ["notion"]
    }
  ]

  @domain_to_archetype %{
    "code" => "developer",
    "design" => "design",
    "data" => "data_scientist",
    "document" => "writer_content",
    "media" => "media_video",
    "slides" => "writer_content",
    "research" => "research",
    "finance" => "finance",
    "marketing" => "marketing",
    "sales" => "sales",
    "sciences" => "sciences",
    "legal" => "legal",
    "ops" => "ops_hr",
    "product" => "product",
    "security" => "security",
    "devops" => "devops",
    "support" => "support_cs"
  }

  @boosts [
    %{
      key: "boost_l3",
      name: "Head start",
      description: "Start at level 3 with a +15 skill bump.",
      credits: 500,
      target_level: 3,
      skill_bonus: 15
    },
    %{
      key: "boost_l5",
      name: "Strong head start",
      description: "Start at level 5 with a +30 skill bump.",
      credits: 1_500,
      target_level: 5,
      skill_bonus: 30
    },
    %{
      key: "boost_l10",
      name: "Specialist ready",
      description: "Start at level 10 with domain knowledge packs preloaded.",
      credits: 5_000,
      target_level: 10,
      skill_bonus: 50
    }
  ]

  def list_archetypes, do: @archetypes

  def list_boosts, do: @boosts

  def specialist_boost_key, do: "boost_l10"

  def specialist_credits do
    case get_boost("boost_l10") do
      %{credits: credits} -> credits
      _ -> 5_000
    end
  end

  def get_archetype(nil), do: get_archetype("blank")
  def get_archetype(""), do: get_archetype("blank")

  def get_archetype(key) when is_binary(key) do
    resolved = Map.get(@aliases, key, key)
    Enum.find(@archetypes, &(&1.key == resolved))
  end

  def get_archetype(_), do: nil

  def get_boost(nil), do: nil
  def get_boost(""), do: nil

  def get_boost(key) when is_binary(key) do
    Enum.find(@boosts, &(&1.key == key))
  end

  def get_boost(_), do: nil

  @doc "Maps a detected mission domain to an archetype key."
  def archetype_key_for_domain(domain) when is_binary(domain) do
    Map.get(@domain_to_archetype, domain, "blank")
  end

  def archetype_key_for_domain(_), do: "blank"

  @doc """
  Builds create attrs from an archetype (+ optional boost). Role/department
  from the client are kept when present; skills/level are always server-owned.
  """
  def build_create_attrs(attrs, archetype_key, boost_key \\ nil) do
    with {:ok, archetype} <- fetch_archetype(archetype_key),
         {:ok, boost} <- fetch_boost(boost_key, archetype) do
      # Paid boosts start at level 1; AgentBoostTrainingWorker applies the climb.
      skill_bonus = 0
      {level, xp, next} = starting_progression(1)
      kind = resolve_kind(attrs)
      seed = skill_seed_for(archetype)

      skills =
        Enum.map(archetype.skills, fn name ->
          %{"name" => name, "level" => min(seed + skill_bonus, 100)}
        end)

      base_caps =
        case attrs do
          %{"capabilities" => caps} when is_map(caps) -> caps
          %{capabilities: caps} when is_map(caps) -> stringify_keys(caps)
          _ -> %{}
        end

      brief = attrs["knowledge_brief"] || attrs[:knowledge_brief]

      capabilities =
        base_caps
        |> maybe_put_brief(brief)
        |> Map.put("learning", %{
          "missions_total" => 0,
          "domain_counts" => %{},
          "specialty" => nil,
          "specialized_at" => nil,
          "role_source" => "archetype",
          "archetype" => archetype.key,
          "tier" => archetype.tier
        })
        |> maybe_put_training(boost, archetype, brief)

      status = if boost, do: "training", else: "idle"

      created =
        attrs
        |> stringify_keys()
        |> Map.drop([
          "skills",
          "level",
          "xp",
          "xp_for_next_level",
          "missions_completed",
          "performance_score",
          "access_scope",
          "archetype_key",
          "boost_key",
          "knowledge_brief"
        ])
        |> Map.merge(%{
          "kind" => kind,
          "role_title" =>
            blank_to_nil(attrs["role_title"] || attrs[:role_title]) || archetype.role_title,
          "department" =>
            blank_to_nil(attrs["department"] || attrs[:department]) || archetype.department,
          "skills" => skills,
          "capabilities" => capabilities,
          "level" => level,
          "xp" => xp,
          "xp_for_next_level" => next,
          "missions_completed" => 0,
          "ai_enabled" => kind in ["ai", "hybrid"],
          "control_mode" =>
            if(kind == "human_linked", do: "human_controlled", else: "ai_controlled"),
          "status" => status
        })

      {:ok, created, archetype, boost}
    end
  end

  defp maybe_put_training(capabilities, nil, _archetype, _brief), do: capabilities

  defp maybe_put_training(capabilities, boost, archetype, brief) do
    Map.put(capabilities, "training", %{
      "boost_key" => boost.key,
      "target_level" => boost.target_level,
      "skill_bonus" => boost.skill_bonus,
      "base_skill_level" => skill_seed_for(archetype),
      "status" => "running",
      "phase" => "leveling",
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "archetype_key" => archetype.key,
      "knowledge_brief" => blank_to_nil(brief),
      "suggested_mcp" => Map.get(archetype, :suggested_mcp) || []
    })
  end

  defp resolve_kind(attrs) do
    case attrs["kind"] || attrs[:kind] || "ai" do
      kind when kind in ["ai", "human_linked", "hybrid"] -> kind
      _ -> "ai"
    end
  end

  defp skill_seed_for(%{tier: "blank"}), do: @blank_skill_seed
  defp skill_seed_for(_), do: @specialist_skill_seed

  @doc "Public catalog for the API/UI."
  def catalog do
    %{
      archetypes:
        Enum.map(@archetypes, fn a ->
          seed = skill_seed_for(a)

          %{
            key: a.key,
            name: a.name,
            domain: a.domain,
            tier: a.tier,
            description: a.description,
            role_title: a.role_title,
            department: a.department,
            tags: a.tags,
            suggested_mcp: a.suggested_mcp,
            corpus_doc_count: DomainPacks.corpus_doc_count(a.key),
            skill_count: DomainPacks.skill_count(a.key),
            credits_for_specialist: if(a.tier == "specialist", do: specialist_credits(), else: 0),
            skills: Enum.map(a.skills, &%{name: &1, level: seed})
          }
        end),
      boosts:
        Enum.map(@boosts, fn b ->
          %{
            key: b.key,
            name: b.name,
            description: b.description,
            credits: b.credits,
            target_level: b.target_level,
            skill_bonus: b.skill_bonus
          }
        end),
      specialist_boost_key: specialist_boost_key(),
      specialist_credits: specialist_credits()
    }
  end

  defp fetch_archetype(key) do
    case get_archetype(key || "blank") do
      nil -> {:error, :invalid_archetype}
      archetype -> {:ok, archetype}
    end
  end

  defp fetch_boost(nil, _archetype), do: {:ok, nil}
  defp fetch_boost("", _archetype), do: {:ok, nil}

  defp fetch_boost(key, archetype) do
    case get_boost(key) do
      nil ->
        {:error, :invalid_boost}

      %{key: "boost_l10"} when archetype.tier == "blank" ->
        {:error, :invalid_boost}

      boost ->
        {:ok, boost}
    end
  end

  # Cumulative XP to reach `target_level` with 0 XP into the next bar.
  defp starting_progression(1), do: {1, 0, Progression.xp_required(1)}

  defp starting_progression(target_level) when target_level > 1 do
    _xp_spent =
      1..(target_level - 1)
      |> Enum.map(&Progression.xp_required/1)
      |> Enum.sum()

    {target_level, 0, Progression.xp_required(target_level)}
  end

  defp maybe_put_brief(caps, brief) when is_binary(brief) and brief != "" do
    Map.put(caps, "knowledge_brief", brief)
  end

  defp maybe_put_brief(caps, _), do: caps

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
