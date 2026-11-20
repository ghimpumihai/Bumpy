import { FlaskConical, Radio, Repeat } from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { QUALITY_LABELS, SOURCE_LABELS } from "@/constants/sessions";
import type { QualityStatus, SessionSource } from "@/types/common";

const QUALITY_VARIANT: Record<QualityStatus, "success" | "warning" | "destructive" | "secondary"> = {
  ok: "success",
  degraded: "warning",
  bad: "destructive",
  pending: "secondary",
};

export function QualityBadge({ status }: { status: QualityStatus }) {
  return <Badge variant={QUALITY_VARIANT[status]}>{QUALITY_LABELS[status]}</Badge>;
}

export function SourceBadge({ source }: { source: SessionSource }) {
  if (source === "live") {
    return (
      <Badge variant="destructive">
        <Radio aria-hidden="true" />
        {SOURCE_LABELS.live}
      </Badge>
    );
  }
  if (source === "replay") {
    return (
      <Badge variant="info">
        <Repeat aria-hidden="true" />
        {SOURCE_LABELS.replay}
      </Badge>
    );
  }
  return <Badge variant="outline">{SOURCE_LABELS.upload}</Badge>;
}

export function MockBadge() {
  return (
    <Badge variant="highlight" title="Generated mock data, not a real recording">
      <FlaskConical aria-hidden="true" />
      Mock
    </Badge>
  );
}
