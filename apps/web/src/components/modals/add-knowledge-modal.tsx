import { useState } from "react";
import { useCreateKnowledge, useKnowledgeCategories } from "@/api/hooks";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field } from "@/components/ui/field";
import { Select } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";

interface AddKnowledgeModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

const typeOptions = [
  { value: "note", label: "Note (write content here)" },
  { value: "document", label: "Document" },
  { value: "link", label: "External link" },
];

export function AddKnowledgeModal({ open, onOpenChange }: AddKnowledgeModalProps) {
  const createKnowledge = useCreateKnowledge();
  const { data: categoriesData } = useKnowledgeCategories();

  const [title, setTitle] = useState("");
  const [type, setType] = useState("note");
  const [categoryId, setCategoryId] = useState<string | undefined>();
  const [body, setBody] = useState("");
  const [sourceUrl, setSourceUrl] = useState("");
  const [tagsText, setTagsText] = useState("");

  const categories = categoriesData?.data ?? [];

  const reset = () => {
    setTitle("");
    setType("note");
    setCategoryId(undefined);
    setBody("");
    setSourceUrl("");
    setTagsText("");
  };

  const handleSubmit = async () => {
    if (!title.trim()) return;
    await createKnowledge.mutateAsync({
      title: title.trim(),
      type,
      body: body.trim() || undefined,
      source_url: type === "link" ? sourceUrl.trim() || undefined : undefined,
      category_id: categoryId,
      status: "published",
      tags: tagsText
        .split(",")
        .map((t) => t.trim())
        .filter(Boolean),
    });
    reset();
    onOpenChange(false);
  };

  return (
    <Dialog
      open={open}
      onOpenChange={onOpenChange}
      title="Add Knowledge"
      description="Content added here is indexed so your agents can use it."
      footer={
        <>
          <Button variant="ghost" size="sm" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button
            size="sm"
            loading={createKnowledge.isPending}
            disabled={!title.trim()}
            onClick={handleSubmit}
          >
            Add Knowledge
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <Field label="Title" required>
          <input
            className="mk-input"
            placeholder="e.g. Brand voice guidelines"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            autoFocus
          />
        </Field>
        <div className="grid grid-cols-2 gap-3">
          <Field label="Type">
            <Select value={type} onValueChange={setType} options={typeOptions} />
          </Field>
          <Field label="Category">
            <Select
              value={categoryId}
              onValueChange={setCategoryId}
              placeholder="Uncategorized"
              options={categories.map((c) => ({ value: c.id, label: c.name }))}
            />
          </Field>
        </div>
        {type === "link" ? (
          <Field label="URL" required>
            <input
              className="mk-input"
              placeholder="https://…"
              value={sourceUrl}
              onChange={(e) => setSourceUrl(e.target.value)}
            />
          </Field>
        ) : (
          <Field label="Content" hint="Markdown supported. This is what agents will read.">
            <Textarea
              className="min-h-[140px]"
              placeholder="Paste or write the content…"
              value={body}
              onChange={(e) => setBody(e.target.value)}
            />
          </Field>
        )}
        <Field label="Tags" hint="Comma-separated">
          <input
            className="mk-input"
            placeholder="brand, marketing…"
            value={tagsText}
            onChange={(e) => setTagsText(e.target.value)}
          />
        </Field>
      </div>
    </Dialog>
  );
}
