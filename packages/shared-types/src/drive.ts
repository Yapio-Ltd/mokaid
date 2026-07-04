export type DriveItemKind = "file" | "folder" | "shortcut";

export type DriveVisibility =
  | "private"
  | "workspace"
  | "project"
  | "restricted"
  | "public_link";

export type DriveItemStatus = "active" | "archived" | "trashed" | "deleted";

export interface DriveItemSummary {
  id: string;
  workspace_id: string;
  parent_id: string | null;
  kind: DriveItemKind;
  name: string;
  mime_type: string | null;
  extension: string | null;
  size_bytes: number | null;
  visibility: DriveVisibility;
  status: DriveItemStatus;
  is_ai_readable: boolean;
  is_system_folder: boolean;
  tags: string[];
  linked_project_id: string | null;
  linked_task_id: string | null;
  linked_agent_id: string | null;
  created_by_name: string | null;
  created_by_kind: "member" | "agent" | null;
  last_modified_by_name: string | null;
  version_count: number;
  child_count: number;
  inserted_at: string;
  updated_at: string;
}

export interface KnowledgeItemSummary {
  id: string;
  workspace_id: string;
  category_id: string | null;
  category_name: string | null;
  title: string;
  type: "document" | "link" | "file" | "note";
  status: "draft" | "processing" | "published" | "archived" | "failed";
  visibility: "workspace" | "restricted" | "private";
  tags: string[];
  version: number;
  used_by_agent_ids: string[];
  created_by_name: string | null;
  updated_at: string;
  inserted_at: string;
}
