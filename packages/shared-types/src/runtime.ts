/** Public task runtime data. Provider billing and credentials never belong here. */
export interface TaskRuntimeArtifact {
  id: string;
  filename: string;
  mime_type?: string | null;
  agent_id?: string | null;
  sha256?: string;
}

export interface TaskRuntimeParticipant {
  agent_id: string;
  name: string;
  status: string;
  assignment?: string;
  /** Filenames; saved Drive identities are carried by the manifest. */
  artifacts?: string[];
}

export interface TaskRuntime {
  engine: "openai_agents";
  status: string;
  participants?: TaskRuntimeParticipant[];
  budget?: {
    limit_credits?: number | null;
    reserved_credits?: number | null;
    used_credits?: number | null;
    remaining_credits?: number | null;
    estimated?: boolean;
    usage_complete?: boolean;
  };
  verification?: {
    checks?: Array<
      string | { name: string; passed?: boolean; message?: string }
    >;
    passed?: boolean;
  };
  limitations?: string[];
  manifest?: TaskRuntimeArtifact[];
}

export interface ManagedRuntimePolicy {
  enabled: boolean;
  data_policy_accepted: boolean;
  data_region: "US";
  zero_data_retention: false;
  max_active_sessions: number;
  standard_credits: number;
  complex_credits: number;
}
