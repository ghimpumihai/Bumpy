import { CircleDashed } from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { INCOMPLETE_DESCRIPTION, QUALITY_LABELS } from "@/constants/sessions";
import type { QualityStatus } from "@/types/common";

const QUALITY_VARIANT: Record<QualityStatus, "success" | "warning" | "destructive" | "secondary"> = {
  ok: "success",
  degraded: "warning",
  bad: "destructive",
  pending: "secondary",
};

export function QualityBadge({ status }: { status: QualityStatus }) {
  return <Badge variant={QUALITY_VARIANT[status]}>{QUALITY_LABELS[status]}</Badge>;
}

export function IncompleteBadge() {
  return (
    <Badge variant="warning" title={INCOMPLETE_DESCRIPTION}>
      <CircleDashed aria-hidden="true" />
      Incomplete
    </Badge>
  );
}
