import { CircleDashed, FlaskConical, Loader2, Radio, Repeat, Upload } from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { INCOMPLETE_DESCRIPTION, QUALITY_LABELS, SOURCE_DESCRIPTIONS, SOURCE_LABELS, STATUS_LABELS } from "@/constants/sessions";
import type { ProcessingStatus, QualityStatus, SessionSource } from "@/types/common";

const QUALITY_VARIANT: Record<QualityStatus, "success" | "warning" | "destructive" | "secondary"> = {
  ok: "success",
  degraded: "warning",
  bad: "destructive",
  pending: "secondary",
};

export function QualityBadge({ status }: { status: QualityStatus }) {
  return <Badge variant={QUALITY_VARIANT[status]}>{QUALITY_LABELS[status]}</Badge>;
}

/** How the trip reached the cloud. */
export function SourceBadge({ source }: { source: SessionSource }) {
  if (source === "replay") {
    return (
      <Badge variant="info" title={SOURCE_DESCRIPTIONS.replay}>
        <Repeat aria-hidden="true" />
        {SOURCE_LABELS.replay}
      </Badge>
    );
  }
  if (source === "upload") {
    return (
      <Badge variant="outline" title={SOURCE_DESCRIPTIONS.upload}>
        <Upload aria-hidden="true" />
        {SOURCE_LABELS.upload}
      </Badge>
    );
  }
  return (
    <Badge variant="outline" title={SOURCE_DESCRIPTIONS.live}>
      {SOURCE_LABELS.live}
    </Badge>
  );
}

/** Recording / Processing; nothing once the trip is finalized (the normal state). */
export function StatusBadge({ status }: { status: ProcessingStatus }) {
  if (status === "live") {
    return (
      <Badge variant="destructive">
        <Radio aria-hidden="true" />
        {STATUS_LABELS.live}
      </Badge>
    );
  }
  if (status === "processing") {
    return (
      <Badge variant="info">
        <Loader2 className="motion-safe:animate-spin" aria-hidden="true" />
        {STATUS_LABELS.processing}
      </Badge>
    );
  }
  return null;
}

export function IncompleteBadge() {
  return (
    <Badge variant="warning" title={INCOMPLETE_DESCRIPTION}>
      <CircleDashed aria-hidden="true" />
      Incomplete
    </Badge>
  );
}

export function MockBadge() {
  return (
    <Badge variant="highlight" title="Generated mock data, not a real recording">
      <FlaskConical aria-hidden="true" />
      Mock
    </Badge>
  );
}
